//! Google and Microsoft agenda adapters backed by GNOME Online Accounts.
//!
//! Refresh tokens remain owned by GOA. This module only asks `TokenSource` for
//! short-lived access tokens and never exposes them through QuickMail models.

use std::{sync::Arc, time::Duration};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, NaiveDate, NaiveDateTime, SecondsFormat, TimeZone, Utc};
use quickmail_core::{Account, CalendarEvent, ProviderError, Task};
use reqwest::Method;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use url::Url;

use super::auth::{GoaMailAccount, GoaProviderFamily, GoaTokenSource, TokenError, TokenSource};

const GOOGLE_CALENDAR_ROOT: &str = "https://www.googleapis.com/calendar/v3/";
const GOOGLE_TASKS_ROOT: &str = "https://tasks.googleapis.com/tasks/v1/";
const MICROSOFT_GRAPH_ROOT: &str = "https://graph.microsoft.com/v1.0/";

const MAX_AGENDA_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_AGENDA_REQUEST_BYTES: usize = 2 * 1024 * 1024;
const MAX_REMOTE_ID_BYTES: usize = 2 * 1024;
const MAX_EXPOSED_ID_BYTES: usize = 8 * 1024;
const MAX_CONTAINER_PAGES: usize = 8;
const MAX_ITEM_PAGES: usize = 32;
const MAX_CONTAINERS: usize = 64;
const MAX_ITEMS: usize = 8_000;
const MAX_CONTINUATION_URL_BYTES: usize = 16 * 1024;

const CALENDAR_ID_PREFIX: &str = "agenda-calendar-v1";
const EVENT_ID_PREFIX: &str = "agenda-event-v1";
const TASK_ID_PREFIX: &str = "agenda-task-v1";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct AgendaSync {
    pub(crate) tasks: Vec<Task>,
    pub(crate) events: Vec<CalendarEvent>,
}

/// Direct calendar/task API access for a QuickMail GOA account.
pub(crate) struct AgendaProvider {
    account: Account,
    family: GoaProviderFamily,
    calendar_enabled: bool,
    tasks_enabled: bool,
    tokens: Arc<dyn TokenSource>,
    client: reqwest::Client,
}

impl AgendaProvider {
    pub(crate) async fn discover(account: &Account) -> Result<Option<Self>, ProviderError> {
        let Some(family) = account_family(account) else {
            return Ok(None);
        };
        let Some(goa) = GoaMailAccount::discover(&account.address, family)
            .await
            .map_err(|error| token_provider_error(family, error))?
        else {
            return Ok(None);
        };
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(90))
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(8)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| ProviderError::Temporary("agenda transport unavailable".into()))?;
        Ok(Some(Self {
            account: account.clone(),
            family,
            calendar_enabled: !goa.calendar_disabled,
            tasks_enabled: !goa.tasks_disabled,
            tokens: Arc::new(GoaTokenSource::new(&goa)),
            client,
        }))
    }

    pub(crate) const fn family(&self) -> GoaProviderFamily {
        self.family
    }

    /// Google Tasks stores due dates at day precision; Microsoft To Do keeps a
    /// date and time zone and therefore supports the UI's due-time control.
    pub(crate) const fn supports_due_time(&self) -> bool {
        matches!(self.family, GoaProviderFamily::Microsoft)
    }

    pub(crate) fn account(&self) -> &Account {
        &self.account
    }

    pub(crate) async fn sync(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<AgendaSync, ProviderError> {
        if end <= start {
            return Err(ProviderError::Other(
                "agenda range must end after it starts".into(),
            ));
        }
        let tasks = async {
            if !self.tasks_enabled {
                return Ok(Vec::new());
            }
            match self.family {
                GoaProviderFamily::Google => self.sync_google_tasks().await,
                GoaProviderFamily::Microsoft => self.sync_microsoft_tasks().await,
            }
        };
        let events = async {
            if !self.calendar_enabled {
                return Ok(Vec::new());
            }
            match self.family {
                GoaProviderFamily::Google => self.sync_google_events(start, end).await,
                GoaProviderFamily::Microsoft => self.sync_microsoft_events(start, end).await,
            }
        };
        let (tasks, events) = tokio::try_join!(tasks, events)?;
        Ok(AgendaSync { tasks, events })
    }

    pub(crate) async fn create_task(&self, task: &Task) -> Result<Task, ProviderError> {
        self.ensure_tasks_enabled()?;
        self.validate_task_account(task)?;
        match self.family {
            GoaProviderFamily::Google => self.create_google_task(task).await,
            GoaProviderFamily::Microsoft => self.create_microsoft_task(task).await,
        }
    }

    pub(crate) async fn update_task(&self, task: &Task) -> Result<Task, ProviderError> {
        self.ensure_tasks_enabled()?;
        self.validate_task_account(task)?;
        match self.family {
            GoaProviderFamily::Google => self.update_google_task(task).await,
            GoaProviderFamily::Microsoft => self.update_microsoft_task(task).await,
        }
    }

    pub(crate) async fn complete_task(
        &self,
        task: &Task,
        done: bool,
    ) -> Result<Task, ProviderError> {
        let mut updated = task.clone();
        updated.done = done;
        self.update_task(&updated).await
    }

    pub(crate) async fn delete_task(&self, task: &Task) -> Result<(), ProviderError> {
        self.ensure_tasks_enabled()?;
        self.validate_task_account(task)?;
        match self.family {
            GoaProviderFamily::Google => self.delete_google_task(task).await,
            GoaProviderFamily::Microsoft => self.delete_microsoft_task(task).await,
        }
    }

    pub(crate) async fn create_event(
        &self,
        event: &CalendarEvent,
    ) -> Result<CalendarEvent, ProviderError> {
        self.ensure_calendar_enabled()?;
        self.validate_event(event, true)?;
        match self.family {
            GoaProviderFamily::Google => self.create_google_event(event).await,
            GoaProviderFamily::Microsoft => self.create_microsoft_event(event).await,
        }
    }

    pub(crate) async fn update_event(
        &self,
        event: &CalendarEvent,
    ) -> Result<CalendarEvent, ProviderError> {
        self.ensure_calendar_enabled()?;
        self.validate_event(event, false)?;
        match self.family {
            GoaProviderFamily::Google => self.update_google_event(event).await,
            GoaProviderFamily::Microsoft => self.update_microsoft_event(event).await,
        }
    }

    pub(crate) async fn delete_event(&self, event: &CalendarEvent) -> Result<(), ProviderError> {
        self.ensure_calendar_enabled()?;
        self.validate_event(event, false)?;
        match self.family {
            GoaProviderFamily::Google => self.delete_google_event(event).await,
            GoaProviderFamily::Microsoft => self.delete_microsoft_event(event).await,
        }
    }

    fn validate_task_account(&self, task: &Task) -> Result<(), ProviderError> {
        if task.account.is_empty() || task.account == self.account.id {
            Ok(())
        } else {
            Err(ProviderError::Other(
                "task belongs to a different QuickMail account".into(),
            ))
        }
    }

    fn ensure_tasks_enabled(&self) -> Result<(), ProviderError> {
        if self.tasks_enabled {
            Ok(())
        } else {
            Err(ProviderError::Unsupported(format!(
                "{} tasks are disabled in GNOME Online Accounts",
                match self.family {
                    GoaProviderFamily::Google => "Google",
                    GoaProviderFamily::Microsoft => "Microsoft To Do",
                }
            )))
        }
    }

    fn ensure_calendar_enabled(&self) -> Result<(), ProviderError> {
        if self.calendar_enabled {
            Ok(())
        } else {
            Err(ProviderError::Unsupported(format!(
                "{} Calendar is disabled in GNOME Online Accounts",
                self.family.display_name()
            )))
        }
    }

    fn validate_event(
        &self,
        event: &CalendarEvent,
        allow_account_container: bool,
    ) -> Result<(), ProviderError> {
        if event.title.trim().is_empty() {
            return Err(ProviderError::Other("event title cannot be empty".into()));
        }
        if event.end_at <= event.start_at {
            return Err(ProviderError::Other(
                "event must end after it starts".into(),
            ));
        }
        if event.all_day
            && (event.start_at.time() != chrono::NaiveTime::default()
                || event.end_at.time() != chrono::NaiveTime::default())
        {
            return Err(ProviderError::Other(
                "all-day events must start and end at UTC midnight".into(),
            ));
        }
        if event.read_only {
            return Err(ProviderError::Unsupported(
                "this remote calendar is read-only".into(),
            ));
        }
        if allow_account_container
            && (event.calendar_id.is_empty() || event.calendar_id == self.account.id)
        {
            return Ok(());
        }
        let (account_id, _) = decode_calendar_id(&event.calendar_id)?;
        if account_id != self.account.id {
            return Err(ProviderError::Other(
                "event belongs to a different QuickMail account".into(),
            ));
        }
        Ok(())
    }

    async fn sync_google_tasks(&self) -> Result<Vec<Task>, ProviderError> {
        let lists = self.google_task_lists().await?;
        let mut tasks = Vec::new();
        for list in lists {
            let mut page_token: Option<String> = None;
            for _ in 0..MAX_ITEM_PAGES {
                let mut url = api_url(ApiRoot::GoogleTasks, &["lists", &list.id, "tasks"])?;
                {
                    let mut query = url.query_pairs_mut();
                    query
                        .append_pair("maxResults", "100")
                        .append_pair("showCompleted", "true")
                        .append_pair("showHidden", "true")
                        .append_pair("showDeleted", "false");
                    if let Some(token) = &page_token {
                        query.append_pair("pageToken", token);
                    }
                }
                let page: GooglePage<GoogleTask> = self.get_json(ApiRoot::GoogleTasks, url).await?;
                for raw in page.items {
                    if let Some(task) = normalize_google_task(&self.account, &list.id, raw)? {
                        push_bounded(&mut tasks, task)?;
                    }
                }
                page_token = page.next_page_token.filter(|token| !token.is_empty());
                if page_token.is_none() {
                    break;
                }
            }
            if page_token.is_some() {
                return Err(page_limit_error("Google Tasks"));
            }
        }
        Ok(tasks)
    }

    async fn sync_google_events(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<CalendarEvent>, ProviderError> {
        let calendars = self.google_calendars().await?;
        let mut events = Vec::new();
        for calendar in calendars {
            let mut page_token: Option<String> = None;
            for _ in 0..MAX_ITEM_PAGES {
                let mut url = api_url(
                    ApiRoot::GoogleCalendar,
                    &["calendars", &calendar.id, "events"],
                )?;
                {
                    let mut query = url.query_pairs_mut();
                    query
                        .append_pair("maxResults", "250")
                        .append_pair("singleEvents", "true")
                        .append_pair("showDeleted", "false")
                        .append_pair("orderBy", "startTime")
                        .append_pair("timeMin", &rfc3339(start))
                        .append_pair("timeMax", &rfc3339(end));
                    if let Some(token) = &page_token {
                        query.append_pair("pageToken", token);
                    }
                }
                let page: GooglePage<GoogleEvent> =
                    self.get_json(ApiRoot::GoogleCalendar, url).await?;
                for raw in page.items {
                    if let Some(event) = normalize_google_event(
                        &self.account,
                        &calendar.id,
                        calendar.is_read_only(),
                        raw,
                    )? {
                        push_bounded(&mut events, event)?;
                    }
                }
                page_token = page.next_page_token.filter(|token| !token.is_empty());
                if page_token.is_none() {
                    break;
                }
            }
            if page_token.is_some() {
                return Err(page_limit_error("Google Calendar"));
            }
        }
        Ok(events)
    }

    async fn sync_microsoft_tasks(&self) -> Result<Vec<Task>, ProviderError> {
        let lists = self.microsoft_task_lists().await?;
        let mut tasks = Vec::new();
        for list in lists {
            let url = api_url(
                ApiRoot::MicrosoftGraph,
                &["me", "todo", "lists", &list.id, "tasks"],
            )?;
            for raw in self
                .graph_collection::<MicrosoftTask>(url, MAX_ITEM_PAGES)
                .await?
            {
                if let Some(task) = normalize_microsoft_task(&self.account, &list.id, raw)? {
                    push_bounded(&mut tasks, task)?;
                }
            }
        }
        Ok(tasks)
    }

    async fn sync_microsoft_events(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<CalendarEvent>, ProviderError> {
        let calendars = self.microsoft_calendars().await?;
        let mut events = Vec::new();
        for calendar in calendars {
            let mut url = api_url(
                ApiRoot::MicrosoftGraph,
                &["me", "calendars", &calendar.id, "calendarView"],
            )?;
            url.query_pairs_mut()
                .append_pair("startDateTime", &rfc3339(start))
                .append_pair("endDateTime", &rfc3339(end))
                .append_pair("$top", "250")
                .append_pair(
                    "$select",
                    "id,subject,body,bodyPreview,start,end,isAllDay,isCancelled",
                );
            for raw in self
                .graph_collection::<MicrosoftEvent>(url, MAX_ITEM_PAGES)
                .await?
            {
                if let Some(event) =
                    normalize_microsoft_event(&self.account, &calendar.id, !calendar.can_edit, raw)?
                {
                    push_bounded(&mut events, event)?;
                }
            }
        }
        Ok(events)
    }

    async fn google_task_lists(&self) -> Result<Vec<GoogleTaskList>, ProviderError> {
        let mut lists = Vec::new();
        let mut page_token: Option<String> = None;
        for _ in 0..MAX_CONTAINER_PAGES {
            let mut url = api_url(ApiRoot::GoogleTasks, &["users", "@me", "lists"])?;
            {
                let mut query = url.query_pairs_mut();
                query.append_pair("maxResults", "100");
                if let Some(token) = &page_token {
                    query.append_pair("pageToken", token);
                }
            }
            let page: GooglePage<GoogleTaskList> = self.get_json(ApiRoot::GoogleTasks, url).await?;
            for list in page.items {
                if !list.id.is_empty() {
                    push_container(&mut lists, list)?;
                }
            }
            page_token = page.next_page_token.filter(|token| !token.is_empty());
            if page_token.is_none() {
                return Ok(lists);
            }
        }
        Err(page_limit_error("Google task lists"))
    }

    async fn google_calendars(&self) -> Result<Vec<GoogleCalendar>, ProviderError> {
        let mut calendars = Vec::new();
        let mut page_token: Option<String> = None;
        for _ in 0..MAX_CONTAINER_PAGES {
            let mut url = api_url(ApiRoot::GoogleCalendar, &["users", "me", "calendarList"])?;
            {
                let mut query = url.query_pairs_mut();
                query.append_pair("maxResults", "100");
                if let Some(token) = &page_token {
                    query.append_pair("pageToken", token);
                }
            }
            let page: GooglePage<GoogleCalendar> =
                self.get_json(ApiRoot::GoogleCalendar, url).await?;
            for calendar in page.items {
                if !calendar.deleted && !calendar.id.is_empty() {
                    push_container(&mut calendars, calendar)?;
                }
            }
            page_token = page.next_page_token.filter(|token| !token.is_empty());
            if page_token.is_none() {
                return Ok(calendars);
            }
        }
        Err(page_limit_error("Google calendars"))
    }

    async fn microsoft_task_lists(&self) -> Result<Vec<MicrosoftTaskList>, ProviderError> {
        let mut url = api_url(ApiRoot::MicrosoftGraph, &["me", "todo", "lists"])?;
        url.query_pairs_mut()
            .append_pair("$top", "100")
            .append_pair("$select", "id,displayName,wellknownListName");
        let lists = self
            .graph_collection::<MicrosoftTaskList>(url, MAX_CONTAINER_PAGES)
            .await?;
        if lists.len() > MAX_CONTAINERS {
            return Err(ProviderError::ResourceTooLarge("remote agenda containers"));
        }
        Ok(lists)
    }

    async fn microsoft_calendars(&self) -> Result<Vec<MicrosoftCalendar>, ProviderError> {
        let mut url = api_url(ApiRoot::MicrosoftGraph, &["me", "calendars"])?;
        url.query_pairs_mut()
            .append_pair("$top", "100")
            .append_pair("$select", "id,name,canEdit,isDefaultCalendar");
        let calendars = self
            .graph_collection::<MicrosoftCalendar>(url, MAX_CONTAINER_PAGES)
            .await?;
        if calendars.len() > MAX_CONTAINERS {
            return Err(ProviderError::ResourceTooLarge("remote agenda containers"));
        }
        Ok(calendars)
    }

    async fn default_google_task_list(&self) -> Result<String, ProviderError> {
        // Google documents `@default` as the stable alias for the authenticated
        // user's default list. Resolve it to the native ID before encoding our
        // task key so a later full sync produces the same QuickMail ID.
        let url = api_url(ApiRoot::GoogleTasks, &["users", "@me", "lists", "@default"])?;
        let list: GoogleTaskList = self.get_json(ApiRoot::GoogleTasks, url).await?;
        checked_remote_id(&list.id).map(str::to_owned)
    }

    async fn default_google_calendar(&self) -> Result<String, ProviderError> {
        let calendars = self.google_calendars().await?;
        calendars
            .iter()
            .find(|calendar| calendar.primary)
            .or_else(|| calendars.iter().find(|calendar| !calendar.is_read_only()))
            .map(|calendar| calendar.id.clone())
            .ok_or(ProviderError::NotFound)
    }

    async fn default_microsoft_task_list(&self) -> Result<String, ProviderError> {
        let lists = self.microsoft_task_lists().await?;
        lists
            .iter()
            .find(|list| list.wellknown_list_name.as_deref() == Some("defaultList"))
            .or_else(|| lists.first())
            .map(|list| list.id.clone())
            .ok_or(ProviderError::NotFound)
    }

    async fn default_microsoft_calendar(&self) -> Result<String, ProviderError> {
        let calendars = self.microsoft_calendars().await?;
        calendars
            .iter()
            .find(|calendar| calendar.is_default_calendar && calendar.can_edit)
            .or_else(|| calendars.iter().find(|calendar| calendar.can_edit))
            .map(|calendar| calendar.id.clone())
            .ok_or(ProviderError::NotFound)
    }

    async fn create_google_task(&self, task: &Task) -> Result<Task, ProviderError> {
        let list_id = self.default_google_task_list().await?;
        let url = api_url(ApiRoot::GoogleTasks, &["lists", &list_id, "tasks"])?;
        let raw: GoogleTask = self
            .send_json(
                ApiRoot::GoogleTasks,
                Method::POST,
                url,
                Some(&google_task_body(task)),
            )
            .await?;
        normalize_google_task(&self.account, &list_id, raw)?.ok_or_else(|| {
            ProviderError::Other("Google returned a deleted task after creation".into())
        })
    }

    async fn update_google_task(&self, task: &Task) -> Result<Task, ProviderError> {
        let (list_id, remote_id) = self.google_task_locator(task).await?;
        let url = api_url(
            ApiRoot::GoogleTasks,
            &["lists", &list_id, "tasks", &remote_id],
        )?;
        let raw: GoogleTask = self
            .send_json(
                ApiRoot::GoogleTasks,
                Method::PATCH,
                url,
                Some(&google_task_body(task)),
            )
            .await?;
        normalize_google_task(&self.account, &list_id, raw)?.ok_or_else(|| {
            ProviderError::Other("Google returned a deleted task after update".into())
        })
    }

    async fn delete_google_task(&self, task: &Task) -> Result<(), ProviderError> {
        let (list_id, remote_id) = self.google_task_locator(task).await?;
        let url = api_url(
            ApiRoot::GoogleTasks,
            &["lists", &list_id, "tasks", &remote_id],
        )?;
        self.send_empty(ApiRoot::GoogleTasks, Method::DELETE, url)
            .await
    }

    async fn google_task_locator(&self, task: &Task) -> Result<(String, String), ProviderError> {
        if let Ok((account_id, list_id, task_id)) = decode_item_id(TASK_ID_PREFIX, &task.id) {
            ensure_same_account(&self.account.id, &account_id)?;
            return Ok((list_id, task_id));
        }
        if task.external_id.is_empty() {
            return Err(ProviderError::NotFound);
        }
        Ok((
            self.default_google_task_list().await?,
            checked_remote_id(&task.external_id)?.to_owned(),
        ))
    }

    async fn create_microsoft_task(&self, task: &Task) -> Result<Task, ProviderError> {
        let list_id = self.default_microsoft_task_list().await?;
        let url = api_url(
            ApiRoot::MicrosoftGraph,
            &["me", "todo", "lists", &list_id, "tasks"],
        )?;
        let raw: MicrosoftTask = self
            .send_json(
                ApiRoot::MicrosoftGraph,
                Method::POST,
                url,
                Some(&microsoft_task_body(task)),
            )
            .await?;
        normalize_microsoft_task(&self.account, &list_id, raw)?.ok_or_else(|| {
            ProviderError::Other("Microsoft returned a deleted task after creation".into())
        })
    }

    async fn update_microsoft_task(&self, task: &Task) -> Result<Task, ProviderError> {
        let (list_id, remote_id) = self.microsoft_task_locator(task).await?;
        let url = api_url(
            ApiRoot::MicrosoftGraph,
            &["me", "todo", "lists", &list_id, "tasks", &remote_id],
        )?;
        let raw: MicrosoftTask = self
            .send_json(
                ApiRoot::MicrosoftGraph,
                Method::PATCH,
                url,
                Some(&microsoft_task_body(task)),
            )
            .await?;
        normalize_microsoft_task(&self.account, &list_id, raw)?.ok_or_else(|| {
            ProviderError::Other("Microsoft returned a deleted task after update".into())
        })
    }

    async fn delete_microsoft_task(&self, task: &Task) -> Result<(), ProviderError> {
        let (list_id, remote_id) = self.microsoft_task_locator(task).await?;
        let url = api_url(
            ApiRoot::MicrosoftGraph,
            &["me", "todo", "lists", &list_id, "tasks", &remote_id],
        )?;
        self.send_empty(ApiRoot::MicrosoftGraph, Method::DELETE, url)
            .await
    }

    async fn microsoft_task_locator(&self, task: &Task) -> Result<(String, String), ProviderError> {
        if let Ok((account_id, list_id, task_id)) = decode_item_id(TASK_ID_PREFIX, &task.id) {
            ensure_same_account(&self.account.id, &account_id)?;
            return Ok((list_id, task_id));
        }
        if task.external_id.is_empty() {
            return Err(ProviderError::NotFound);
        }
        Ok((
            self.default_microsoft_task_list().await?,
            checked_remote_id(&task.external_id)?.to_owned(),
        ))
    }

    async fn create_google_event(
        &self,
        event: &CalendarEvent,
    ) -> Result<CalendarEvent, ProviderError> {
        let calendar_id = self.google_event_container(event).await?;
        let url = api_url(
            ApiRoot::GoogleCalendar,
            &["calendars", &calendar_id, "events"],
        )?;
        let raw: GoogleEvent = self
            .send_json(
                ApiRoot::GoogleCalendar,
                Method::POST,
                url,
                Some(&google_event_body(event)),
            )
            .await?;
        normalize_google_event(&self.account, &calendar_id, false, raw)?.ok_or_else(|| {
            ProviderError::Other("Google returned a cancelled event after creation".into())
        })
    }

    async fn update_google_event(
        &self,
        event: &CalendarEvent,
    ) -> Result<CalendarEvent, ProviderError> {
        let (calendar_id, remote_id) = self.google_event_locator(event).await?;
        let url = api_url(
            ApiRoot::GoogleCalendar,
            &["calendars", &calendar_id, "events", &remote_id],
        )?;
        let raw: GoogleEvent = self
            .send_json(
                ApiRoot::GoogleCalendar,
                Method::PATCH,
                url,
                Some(&google_event_body(event)),
            )
            .await?;
        normalize_google_event(&self.account, &calendar_id, false, raw)?.ok_or_else(|| {
            ProviderError::Other("Google returned a cancelled event after update".into())
        })
    }

    async fn delete_google_event(&self, event: &CalendarEvent) -> Result<(), ProviderError> {
        let (calendar_id, remote_id) = self.google_event_locator(event).await?;
        let url = api_url(
            ApiRoot::GoogleCalendar,
            &["calendars", &calendar_id, "events", &remote_id],
        )?;
        self.send_empty(ApiRoot::GoogleCalendar, Method::DELETE, url)
            .await
    }

    async fn google_event_container(&self, event: &CalendarEvent) -> Result<String, ProviderError> {
        if event.calendar_id.is_empty() || event.calendar_id == self.account.id {
            self.default_google_calendar().await
        } else {
            let (account_id, container_id) = decode_calendar_id(&event.calendar_id)?;
            ensure_same_account(&self.account.id, &account_id)?;
            Ok(container_id)
        }
    }

    async fn google_event_locator(
        &self,
        event: &CalendarEvent,
    ) -> Result<(String, String), ProviderError> {
        if let Ok((account_id, calendar_id, event_id)) = decode_item_id(EVENT_ID_PREFIX, &event.id)
        {
            ensure_same_account(&self.account.id, &account_id)?;
            return Ok((calendar_id, event_id));
        }
        if event.external_id.is_empty() {
            return Err(ProviderError::NotFound);
        }
        Ok((
            self.google_event_container(event).await?,
            checked_remote_id(&event.external_id)?.to_owned(),
        ))
    }

    async fn create_microsoft_event(
        &self,
        event: &CalendarEvent,
    ) -> Result<CalendarEvent, ProviderError> {
        let calendar_id = self.microsoft_event_container(event).await?;
        let url = api_url(
            ApiRoot::MicrosoftGraph,
            &["me", "calendars", &calendar_id, "events"],
        )?;
        let raw: MicrosoftEvent = self
            .send_json(
                ApiRoot::MicrosoftGraph,
                Method::POST,
                url,
                Some(&microsoft_event_body(event)),
            )
            .await?;
        normalize_microsoft_event(&self.account, &calendar_id, false, raw)?.ok_or_else(|| {
            ProviderError::Other("Microsoft returned a cancelled event after creation".into())
        })
    }

    async fn update_microsoft_event(
        &self,
        event: &CalendarEvent,
    ) -> Result<CalendarEvent, ProviderError> {
        let (calendar_id, remote_id) = self.microsoft_event_locator(event).await?;
        let url = api_url(
            ApiRoot::MicrosoftGraph,
            &["me", "calendars", &calendar_id, "events", &remote_id],
        )?;
        let raw: MicrosoftEvent = self
            .send_json(
                ApiRoot::MicrosoftGraph,
                Method::PATCH,
                url,
                Some(&microsoft_event_body(event)),
            )
            .await?;
        normalize_microsoft_event(&self.account, &calendar_id, false, raw)?.ok_or_else(|| {
            ProviderError::Other("Microsoft returned a cancelled event after update".into())
        })
    }

    async fn delete_microsoft_event(&self, event: &CalendarEvent) -> Result<(), ProviderError> {
        let (calendar_id, remote_id) = self.microsoft_event_locator(event).await?;
        let url = api_url(
            ApiRoot::MicrosoftGraph,
            &["me", "calendars", &calendar_id, "events", &remote_id],
        )?;
        self.send_empty(ApiRoot::MicrosoftGraph, Method::DELETE, url)
            .await
    }

    async fn microsoft_event_container(
        &self,
        event: &CalendarEvent,
    ) -> Result<String, ProviderError> {
        if event.calendar_id.is_empty() || event.calendar_id == self.account.id {
            self.default_microsoft_calendar().await
        } else {
            let (account_id, container_id) = decode_calendar_id(&event.calendar_id)?;
            ensure_same_account(&self.account.id, &account_id)?;
            Ok(container_id)
        }
    }

    async fn microsoft_event_locator(
        &self,
        event: &CalendarEvent,
    ) -> Result<(String, String), ProviderError> {
        if let Ok((account_id, calendar_id, event_id)) = decode_item_id(EVENT_ID_PREFIX, &event.id)
        {
            ensure_same_account(&self.account.id, &account_id)?;
            return Ok((calendar_id, event_id));
        }
        if event.external_id.is_empty() {
            return Err(ProviderError::NotFound);
        }
        Ok((
            self.microsoft_event_container(event).await?,
            checked_remote_id(&event.external_id)?.to_owned(),
        ))
    }

    async fn graph_collection<T: DeserializeOwned + Default>(
        &self,
        mut url: Url,
        max_pages: usize,
    ) -> Result<Vec<T>, ProviderError> {
        let mut output = Vec::new();
        for _ in 0..max_pages {
            let page: GraphPage<T> = self.get_json(ApiRoot::MicrosoftGraph, url).await?;
            for item in page.value {
                push_bounded(&mut output, item)?;
            }
            let Some(next) = page.next_link else {
                return Ok(output);
            };
            url = continuation_url(ApiRoot::MicrosoftGraph, &next)?;
        }
        Err(page_limit_error("Microsoft Graph"))
    }

    async fn get_json<T: DeserializeOwned>(
        &self,
        root: ApiRoot,
        url: Url,
    ) -> Result<T, ProviderError> {
        self.send_json::<Value, T>(root, Method::GET, url, None)
            .await
    }

    async fn send_empty(
        &self,
        root: ApiRoot,
        method: Method,
        url: Url,
    ) -> Result<(), ProviderError> {
        let body = self.request(root, method, url, None).await?;
        if body.is_empty() {
            Ok(())
        } else {
            // Some providers return a small JSON resource on a successful
            // delete. It is already bounded and does not need to cross layers.
            serde_json::from_slice::<Value>(&body)
                .map(|_| ())
                .map_err(|_| ProviderError::Other("agenda provider returned malformed JSON".into()))
        }
    }

    async fn send_json<B: Serialize + ?Sized, T: DeserializeOwned>(
        &self,
        root: ApiRoot,
        method: Method,
        url: Url,
        value: Option<&B>,
    ) -> Result<T, ProviderError> {
        let body = value
            .map(|value| {
                serde_json::to_vec(value)
                    .map_err(|_| ProviderError::Other("agenda request is not valid JSON".into()))
            })
            .transpose()?;
        if body
            .as_ref()
            .is_some_and(|body| body.len() > MAX_AGENDA_REQUEST_BYTES)
        {
            return Err(ProviderError::ResourceTooLarge("agenda request"));
        }
        let response = self.request(root, method, url, body).await?;
        serde_json::from_slice(&response)
            .map_err(|_| ProviderError::Other("agenda provider returned malformed JSON".into()))
    }

    async fn request(
        &self,
        root: ApiRoot,
        method: Method,
        url: Url,
        body: Option<Vec<u8>>,
    ) -> Result<Vec<u8>, ProviderError> {
        validate_api_url(root, &url)?;
        for force_refresh in [false, true] {
            let token = self
                .tokens
                .access_token(force_refresh)
                .await
                .map_err(|error| token_provider_error(self.family, error))?;
            let mut request = self
                .client
                .request(method.clone(), url.clone())
                .bearer_auth(token.value.expose_secret())
                .header(reqwest::header::ACCEPT, "application/json");
            if matches!(root, ApiRoot::MicrosoftGraph) {
                request = request.header(
                    "Prefer",
                    "outlook.timezone=\"UTC\", outlook.body-content-type=\"text\"",
                );
            }
            if let Some(body) = &body {
                request = request
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(body.clone());
            }
            let mut response = request
                .send()
                .await
                .map_err(|_| ProviderError::Temporary("agenda provider transport failed".into()))?;
            let status = response.status().as_u16();
            let response_body = read_bounded_body(&mut response).await?;
            if status == 401 && !force_refresh {
                continue;
            }
            if !(200..300).contains(&status) {
                return Err(http_provider_error(self.family, status, &response_body));
            }
            return Ok(response_body);
        }
        Err(ProviderError::Authentication(format!(
            "{} Online Account authorization expired",
            self.family.display_name()
        )))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApiRoot {
    GoogleCalendar,
    GoogleTasks,
    MicrosoftGraph,
}

impl ApiRoot {
    const fn base(self) -> &'static str {
        match self {
            Self::GoogleCalendar => GOOGLE_CALENDAR_ROOT,
            Self::GoogleTasks => GOOGLE_TASKS_ROOT,
            Self::MicrosoftGraph => MICROSOFT_GRAPH_ROOT,
        }
    }

    const fn host(self) -> &'static str {
        match self {
            Self::GoogleCalendar => "www.googleapis.com",
            Self::GoogleTasks => "tasks.googleapis.com",
            Self::MicrosoftGraph => "graph.microsoft.com",
        }
    }

    const fn path_prefix(self) -> &'static str {
        match self {
            Self::GoogleCalendar => "/calendar/v3/",
            Self::GoogleTasks => "/tasks/v1/",
            Self::MicrosoftGraph => "/v1.0/",
        }
    }
}

fn account_family(account: &Account) -> Option<GoaProviderFamily> {
    let provider = account.provider.trim().to_ascii_lowercase();
    let protocol = account.protocol.trim().to_ascii_lowercase();
    if matches!(provider.as_str(), "gmail" | "google") {
        Some(GoaProviderFamily::Google)
    } else if matches!(
        provider.as_str(),
        "outlook" | "hotmail" | "microsoft" | "microsoft365" | "office365"
    ) || protocol == "microsoft_graph"
    {
        Some(GoaProviderFamily::Microsoft)
    } else {
        None
    }
}

fn api_url(root: ApiRoot, path: &[&str]) -> Result<Url, ProviderError> {
    let mut url = Url::parse(root.base())
        .map_err(|_| ProviderError::Other("invalid built-in agenda API root".into()))?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| ProviderError::Other("invalid built-in agenda API root".into()))?;
        segments.pop_if_empty();
        for segment in path {
            checked_remote_id(segment)?;
            segments.push(segment);
        }
    }
    validate_api_url(root, &url)?;
    Ok(url)
}

fn continuation_url(root: ApiRoot, value: &str) -> Result<Url, ProviderError> {
    if value.len() > MAX_CONTINUATION_URL_BYTES {
        return Err(ProviderError::ResourceTooLarge("agenda continuation URL"));
    }
    let url = Url::parse(value)
        .map_err(|_| ProviderError::Other("invalid agenda continuation URL".into()))?;
    validate_api_url(root, &url)?;
    Ok(url)
}

fn validate_api_url(root: ApiRoot, url: &Url) -> Result<(), ProviderError> {
    let default_port = url.port().is_none() || url.port() == Some(443);
    let valid = url.scheme() == "https"
        && url.host_str() == Some(root.host())
        && default_port
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
        && url.path().starts_with(root.path_prefix());
    if valid {
        Ok(())
    } else {
        Err(ProviderError::Other(
            "agenda provider refused a non-allowlisted URL".into(),
        ))
    }
}

async fn read_bounded_body(response: &mut reqwest::Response) -> Result<Vec<u8>, ProviderError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_AGENDA_RESPONSE_BYTES as u64)
    {
        return Err(ProviderError::ResourceTooLarge("agenda response"));
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(MAX_AGENDA_RESPONSE_BYTES as u64) as usize,
    );
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| ProviderError::Temporary("agenda response transfer failed".into()))?
    {
        if chunk.len() > MAX_AGENDA_RESPONSE_BYTES.saturating_sub(body.len()) {
            return Err(ProviderError::ResourceTooLarge("agenda response"));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn token_provider_error(family: GoaProviderFamily, error: TokenError) -> ProviderError {
    ProviderError::Authentication(format!(
        "{} Online Account requires authorization: {error}",
        family.display_name()
    ))
}

fn http_provider_error(family: GoaProviderFamily, status: u16, body: &[u8]) -> ProviderError {
    match status {
        401 => ProviderError::Authentication(format!(
            "{} Online Account authorization expired",
            family.display_name()
        )),
        403 => {
            let permission = match family {
                GoaProviderFamily::Google => "Google Calendar and Tasks",
                GoaProviderFamily::Microsoft => "Microsoft Calendars.ReadWrite and Tasks.ReadWrite",
            };
            ProviderError::Authentication(format!(
                "{} Online Account has not granted {permission} access; reconnect the account in GNOME Online Accounts",
                family.display_name()
            ))
        }
        404 => ProviderError::NotFound,
        408 | 425 | 429 => {
            ProviderError::Temporary("agenda provider is temporarily unavailable".into())
        }
        500..=599 => ProviderError::Temporary("agenda provider is temporarily unavailable".into()),
        413 => ProviderError::ResourceTooLarge("agenda provider data"),
        _ => ProviderError::Other(format!(
            "agenda provider rejected the request (HTTP {status}, {})",
            sanitized_error_code(body)
        )),
    }
}

fn sanitized_error_code(body: &[u8]) -> String {
    let value = serde_json::from_slice::<Value>(body).unwrap_or(Value::Null);
    let candidate = value
        .pointer("/error/code")
        .and_then(Value::as_str)
        .or_else(|| value.pointer("/error/status").and_then(Value::as_str))
        .unwrap_or("requestRejected");
    let code = candidate
        .chars()
        .filter(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
        .take(64)
        .collect::<String>();
    if code.is_empty() {
        "requestRejected".into()
    } else {
        code
    }
}

fn checked_remote_id(value: &str) -> Result<&str, ProviderError> {
    if value.is_empty() || value.len() > MAX_REMOTE_ID_BYTES || value.chars().any(char::is_control)
    {
        Err(ProviderError::Other("invalid remote agenda ID".into()))
    } else {
        Ok(value)
    }
}

fn encode_component(value: &str) -> Result<String, ProviderError> {
    checked_remote_id(value)?;
    Ok(URL_SAFE_NO_PAD.encode(value.as_bytes()))
}

fn decode_component(value: &str) -> Result<String, ProviderError> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ProviderError::Other("invalid remote agenda ID".into()))?;
    let value = String::from_utf8(bytes)
        .map_err(|_| ProviderError::Other("invalid remote agenda ID".into()))?;
    checked_remote_id(&value)?;
    Ok(value)
}

fn calendar_id(account_id: &str, remote_calendar_id: &str) -> Result<String, ProviderError> {
    checked_remote_id(account_id)?;
    let value = format!(
        "{account_id}:{CALENDAR_ID_PREFIX}.{}",
        encode_component(remote_calendar_id)?
    );
    bounded_exposed_id(value)
}

fn decode_calendar_id(value: &str) -> Result<(String, String), ProviderError> {
    if value.len() > MAX_EXPOSED_ID_BYTES {
        return Err(ProviderError::Other("invalid remote agenda ID".into()));
    }
    let marker = format!(":{CALENDAR_ID_PREFIX}.");
    let (account, calendar) = value
        .rsplit_once(&marker)
        .ok_or_else(|| ProviderError::Other("invalid remote calendar ID".into()))?;
    checked_remote_id(account)?;
    Ok((account.to_owned(), decode_component(calendar)?))
}

fn item_id(
    prefix: &str,
    account_id: &str,
    container_id: &str,
    remote_id: &str,
) -> Result<String, ProviderError> {
    let value = format!(
        "{prefix}.{}.{}.{}",
        encode_component(account_id)?,
        encode_component(container_id)?,
        encode_component(remote_id)?
    );
    bounded_exposed_id(value)
}

fn decode_item_id(prefix: &str, value: &str) -> Result<(String, String, String), ProviderError> {
    if value.len() > MAX_EXPOSED_ID_BYTES {
        return Err(ProviderError::Other("invalid remote agenda ID".into()));
    }
    let mut parts = value.split('.');
    if parts.next() != Some(prefix) {
        return Err(ProviderError::Other("invalid remote agenda ID".into()));
    }
    let account = parts
        .next()
        .ok_or_else(|| ProviderError::Other("invalid remote agenda ID".into()))?;
    let container = parts
        .next()
        .ok_or_else(|| ProviderError::Other("invalid remote agenda ID".into()))?;
    let item = parts
        .next()
        .ok_or_else(|| ProviderError::Other("invalid remote agenda ID".into()))?;
    if parts.next().is_some() {
        return Err(ProviderError::Other("invalid remote agenda ID".into()));
    }
    Ok((
        decode_component(account)?,
        decode_component(container)?,
        decode_component(item)?,
    ))
}

fn bounded_exposed_id(value: String) -> Result<String, ProviderError> {
    if value.len() > MAX_EXPOSED_ID_BYTES {
        Err(ProviderError::ResourceTooLarge("remote agenda ID"))
    } else {
        Ok(value)
    }
}

fn ensure_same_account(expected: &str, actual: &str) -> Result<(), ProviderError> {
    if expected == actual {
        Ok(())
    } else {
        Err(ProviderError::Other(
            "agenda item belongs to a different QuickMail account".into(),
        ))
    }
}

fn push_bounded<T>(items: &mut Vec<T>, item: T) -> Result<(), ProviderError> {
    if items.len() >= MAX_ITEMS {
        return Err(ProviderError::ResourceTooLarge("remote agenda items"));
    }
    items.push(item);
    Ok(())
}

fn push_container<T>(items: &mut Vec<T>, item: T) -> Result<(), ProviderError> {
    if items.len() >= MAX_CONTAINERS {
        return Err(ProviderError::ResourceTooLarge("remote agenda containers"));
    }
    items.push(item);
    Ok(())
}

fn page_limit_error(provider: &str) -> ProviderError {
    ProviderError::ResourceTooLarge(match provider {
        "Google Tasks" => "Google Tasks pages",
        "Google Calendar" => "Google Calendar pages",
        "Google task lists" => "Google task-list pages",
        "Google calendars" => "Google calendar-list pages",
        "Microsoft Graph" => "Microsoft Graph pages",
        _ => "agenda pages",
    })
}

fn account_label(account: &Account) -> String {
    if account.display_name.trim().is_empty() {
        account.address.clone()
    } else {
        account.display_name.clone()
    }
}

fn rfc3339(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GooglePage<T> {
    #[serde(default)]
    items: Vec<T>,
    next_page_token: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct GraphPage<T> {
    #[serde(default)]
    value: Vec<T>,
    #[serde(rename = "@odata.nextLink")]
    next_link: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct GoogleTaskList {
    id: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleCalendar {
    id: String,
    #[serde(default)]
    primary: bool,
    #[serde(default)]
    deleted: bool,
    #[serde(default)]
    access_role: String,
}

impl GoogleCalendar {
    fn is_read_only(&self) -> bool {
        !matches!(self.access_role.as_str(), "owner" | "writer")
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleTask {
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    notes: String,
    #[serde(default)]
    status: String,
    due: Option<String>,
    updated: Option<String>,
    #[serde(default)]
    deleted: bool,
    #[serde(default)]
    hidden: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleEvent {
    id: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    description: String,
    start: Option<GoogleEventTime>,
    end: Option<GoogleEventTime>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleEventTime {
    date_time: Option<String>,
    date: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MicrosoftTaskList {
    id: String,
    wellknown_list_name: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MicrosoftCalendar {
    id: String,
    #[serde(default)]
    can_edit: bool,
    #[serde(default)]
    is_default_calendar: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MicrosoftTask {
    id: String,
    #[serde(default)]
    title: String,
    body: Option<MicrosoftBody>,
    #[serde(default)]
    status: String,
    due_date_time: Option<MicrosoftDateTime>,
    created_date_time: Option<String>,
    #[serde(default)]
    is_deleted: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MicrosoftEvent {
    id: String,
    #[serde(default)]
    subject: String,
    body: Option<MicrosoftBody>,
    #[serde(default)]
    body_preview: String,
    start: Option<MicrosoftDateTime>,
    end: Option<MicrosoftDateTime>,
    #[serde(default)]
    is_all_day: bool,
    #[serde(default)]
    is_cancelled: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MicrosoftBody {
    #[serde(default)]
    content: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct MicrosoftDateTime {
    date_time: String,
    time_zone: String,
}

fn normalize_google_task(
    account: &Account,
    list_id: &str,
    raw: GoogleTask,
) -> Result<Option<Task>, ProviderError> {
    if raw.deleted || raw.hidden {
        return Ok(None);
    }
    let remote_id = checked_remote_id(&raw.id)?.to_owned();
    let due_at = raw.due.as_deref().map(parse_google_due).transpose()?;
    let updated = raw.updated.as_deref().map(parse_rfc3339).transpose()?;
    Ok(Some(Task {
        id: item_id(TASK_ID_PREFIX, &account.id, list_id, &remote_id)?,
        title: raw.title,
        description: raw.notes,
        done: raw.status == "completed",
        due_at,
        created_at: updated.or(due_at).unwrap_or_else(Utc::now),
        source: "google_tasks".into(),
        external_id: remote_id,
        account: account.id.clone(),
    }))
}

fn normalize_google_event(
    account: &Account,
    remote_calendar_id: &str,
    read_only: bool,
    raw: GoogleEvent,
) -> Result<Option<CalendarEvent>, ProviderError> {
    if raw.status == "cancelled" {
        return Ok(None);
    }
    let remote_id = checked_remote_id(&raw.id)?.to_owned();
    let start = raw
        .start
        .as_ref()
        .ok_or_else(|| ProviderError::Other("Google event has no start".into()))?;
    let end = raw
        .end
        .as_ref()
        .ok_or_else(|| ProviderError::Other("Google event has no end".into()))?;
    let all_day = start.date.is_some();
    let start_at = parse_google_event_time(start)?;
    let end_at = parse_google_event_time(end)?;
    if end_at <= start_at {
        return Err(ProviderError::Other(
            "Google event has an invalid time range".into(),
        ));
    }
    Ok(Some(CalendarEvent {
        id: item_id(EVENT_ID_PREFIX, &account.id, remote_calendar_id, &remote_id)?,
        external_id: remote_id,
        calendar_id: calendar_id(&account.id, remote_calendar_id)?,
        calendar_name: account_label(account),
        title: raw.summary,
        description: raw.description,
        start_at,
        end_at,
        all_day,
        read_only,
    }))
}

fn normalize_microsoft_task(
    account: &Account,
    list_id: &str,
    raw: MicrosoftTask,
) -> Result<Option<Task>, ProviderError> {
    if raw.is_deleted {
        return Ok(None);
    }
    let remote_id = checked_remote_id(&raw.id)?.to_owned();
    let due_at = raw
        .due_date_time
        .as_ref()
        .map(parse_microsoft_datetime)
        .transpose()?;
    let created_at = raw
        .created_date_time
        .as_deref()
        .map(parse_rfc3339)
        .transpose()?
        .or(due_at)
        .unwrap_or_else(Utc::now);
    Ok(Some(Task {
        id: item_id(TASK_ID_PREFIX, &account.id, list_id, &remote_id)?,
        title: raw.title,
        description: raw.body.map(|body| body.content).unwrap_or_default(),
        done: raw.status == "completed",
        due_at,
        created_at,
        source: "microsoft_todo".into(),
        external_id: remote_id,
        account: account.id.clone(),
    }))
}

fn normalize_microsoft_event(
    account: &Account,
    remote_calendar_id: &str,
    read_only: bool,
    raw: MicrosoftEvent,
) -> Result<Option<CalendarEvent>, ProviderError> {
    if raw.is_cancelled {
        return Ok(None);
    }
    let remote_id = checked_remote_id(&raw.id)?.to_owned();
    let start_at = raw
        .start
        .as_ref()
        .ok_or_else(|| ProviderError::Other("Microsoft event has no start".into()))
        .and_then(parse_microsoft_datetime)?;
    let end_at = raw
        .end
        .as_ref()
        .ok_or_else(|| ProviderError::Other("Microsoft event has no end".into()))
        .and_then(parse_microsoft_datetime)?;
    if end_at <= start_at {
        return Err(ProviderError::Other(
            "Microsoft event has an invalid time range".into(),
        ));
    }
    Ok(Some(CalendarEvent {
        id: item_id(EVENT_ID_PREFIX, &account.id, remote_calendar_id, &remote_id)?,
        external_id: remote_id,
        calendar_id: calendar_id(&account.id, remote_calendar_id)?,
        calendar_name: account_label(account),
        title: raw.subject,
        description: raw
            .body
            .map(|body| body.content)
            .unwrap_or(raw.body_preview),
        start_at,
        end_at,
        all_day: raw.is_all_day,
        read_only,
    }))
}

fn parse_google_due(value: &str) -> Result<DateTime<Utc>, ProviderError> {
    // Google Tasks ignores the time component. Normalizing to UTC midnight
    // makes that limitation explicit and stable in the provider-neutral model.
    let date = value
        .get(..10)
        .and_then(|date| NaiveDate::parse_from_str(date, "%Y-%m-%d").ok())
        .ok_or_else(|| ProviderError::Other("Google task has an invalid due date".into()))?;
    Ok(Utc.from_utc_datetime(
        &date
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| ProviderError::Other("Google task has an invalid due date".into()))?,
    ))
}

fn parse_google_event_time(value: &GoogleEventTime) -> Result<DateTime<Utc>, ProviderError> {
    if let Some(date_time) = &value.date_time {
        return parse_rfc3339(date_time);
    }
    let date = value
        .date
        .as_deref()
        .and_then(|date| NaiveDate::parse_from_str(date, "%Y-%m-%d").ok())
        .ok_or_else(|| ProviderError::Other("Google event has an invalid date".into()))?;
    Ok(Utc.from_utc_datetime(
        &date
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| ProviderError::Other("Google event has an invalid date".into()))?,
    ))
}

fn parse_rfc3339(value: &str) -> Result<DateTime<Utc>, ProviderError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|_| ProviderError::Other("agenda provider returned an invalid timestamp".into()))
}

fn parse_microsoft_datetime(value: &MicrosoftDateTime) -> Result<DateTime<Utc>, ProviderError> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(&value.date_time) {
        return Ok(parsed.with_timezone(&Utc));
    }
    // Requests set `Prefer: outlook.timezone="UTC"`, so Graph's offset-less
    // dateTime values are UTC. The timeZone field is still checked to avoid
    // silently treating a provider regression as a correct instant.
    if !matches!(value.time_zone.as_str(), "UTC" | "Etc/UTC" | "GMT") {
        return Err(ProviderError::Unsupported(format!(
            "Microsoft returned unsupported agenda time zone {}",
            value
                .time_zone
                .chars()
                .filter(|character| character.is_ascii_alphanumeric() || *character == '/')
                .take(64)
                .collect::<String>()
        )));
    }
    parse_naive_datetime(&value.date_time)
        .map(|value| Utc.from_utc_datetime(&value))
        .ok_or_else(|| ProviderError::Other("Microsoft returned an invalid timestamp".into()))
}

fn parse_naive_datetime(value: &str) -> Option<NaiveDateTime> {
    [
        "%Y-%m-%dT%H:%M:%S%.f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S%.f",
    ]
    .into_iter()
    .find_map(|format| NaiveDateTime::parse_from_str(value, format).ok())
}

fn google_task_body(task: &Task) -> Value {
    json!({
        "title": task.title,
        "notes": task.description,
        "status": if task.done { "completed" } else { "needsAction" },
        "completed": if task.done { Some(rfc3339(Utc::now())) } else { None },
        "due": task.due_at.map(|due| format!("{}T00:00:00.000Z", due.date_naive())),
    })
}

fn microsoft_task_body(task: &Task) -> Value {
    json!({
        "title": task.title,
        "body": {
            "content": task.description,
            "contentType": "text"
        },
        "status": if task.done { "completed" } else { "notStarted" },
        "dueDateTime": task.due_at.map(microsoft_datetime),
    })
}

fn google_event_body(event: &CalendarEvent) -> Value {
    let (start, end) = if event.all_day {
        (
            json!({ "date": event.start_at.date_naive().to_string() }),
            json!({ "date": event.end_at.date_naive().to_string() }),
        )
    } else {
        (
            json!({ "dateTime": rfc3339(event.start_at), "timeZone": "UTC" }),
            json!({ "dateTime": rfc3339(event.end_at), "timeZone": "UTC" }),
        )
    };
    json!({
        "summary": event.title,
        "description": event.description,
        "start": start,
        "end": end,
    })
}

fn microsoft_event_body(event: &CalendarEvent) -> Value {
    json!({
        "subject": event.title,
        "body": {
            "content": event.description,
            "contentType": "text"
        },
        "start": microsoft_datetime(event.start_at),
        "end": microsoft_datetime(event.end_at),
        "isAllDay": event.all_day,
    })
}

fn microsoft_datetime(value: DateTime<Utc>) -> MicrosoftDateTime {
    MicrosoftDateTime {
        date_time: value.format("%Y-%m-%dT%H:%M:%S%.3f").to_string(),
        time_zone: "UTC".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct PanicTokens;

    #[async_trait::async_trait]
    impl TokenSource for PanicTokens {
        async fn access_token(
            &self,
            _force_refresh: bool,
        ) -> Result<super::super::auth::AccessToken, TokenError> {
            panic!("a disabled GOA service must not request an access token")
        }
    }

    fn account(provider: &str) -> Account {
        Account {
            id: "account/one".into(),
            address: "person@example.com".into(),
            display_name: "Person".into(),
            provider: provider.into(),
            protocol: String::new(),
            host: String::new(),
            unread: 0,
            total: 0,
            enabled: true,
        }
    }

    fn disabled_provider(family: GoaProviderFamily) -> AgendaProvider {
        AgendaProvider {
            account: account(match family {
                GoaProviderFamily::Google => "gmail",
                GoaProviderFamily::Microsoft => "outlook",
            }),
            family,
            calendar_enabled: false,
            tasks_enabled: false,
            tokens: Arc::new(PanicTokens),
            client: reqwest::Client::new(),
        }
    }

    #[tokio::test]
    async fn disabled_goa_services_never_request_tokens_or_remote_data() {
        let provider = disabled_provider(GoaProviderFamily::Microsoft);
        let start = Utc.with_ymd_and_hms(2026, 9, 1, 0, 0, 0).unwrap();
        let end = start + chrono::Duration::days(1);
        assert_eq!(
            provider.sync(start, end).await.unwrap(),
            AgendaSync::default()
        );

        let task = Task {
            id: String::new(),
            title: "Private task".into(),
            description: String::new(),
            done: false,
            due_at: None,
            created_at: start,
            source: "microsoft_todo".into(),
            external_id: String::new(),
            account: "account/one".into(),
        };
        assert!(matches!(
            provider.create_task(&task).await,
            Err(ProviderError::Unsupported(message)) if message.contains("Microsoft To Do")
        ));

        let event = CalendarEvent {
            id: String::new(),
            external_id: String::new(),
            calendar_id: "account/one".into(),
            calendar_name: String::new(),
            title: "Private event".into(),
            description: String::new(),
            start_at: start,
            end_at: end,
            all_day: false,
            read_only: false,
        };
        assert!(matches!(
            provider.create_event(&event).await,
            Err(ProviderError::Unsupported(message)) if message.contains("Microsoft Calendar")
        ));
    }

    #[test]
    fn identifiers_round_trip_provider_characters_and_scope_the_account() {
        let calendar = calendar_id("account:one", "remote:calendar@example.com").unwrap();
        assert!(calendar.starts_with("account:one:agenda-calendar-v1."));
        assert_eq!(
            decode_calendar_id(&calendar).unwrap(),
            ("account:one".into(), "remote:calendar@example.com".into())
        );

        let event = item_id(
            EVENT_ID_PREFIX,
            "account/one",
            "remote:calendar@example.com",
            "event/with+characters==",
        )
        .unwrap();
        assert_eq!(
            decode_item_id(EVENT_ID_PREFIX, &event).unwrap(),
            (
                "account/one".into(),
                "remote:calendar@example.com".into(),
                "event/with+characters==".into()
            )
        );
    }

    #[test]
    fn google_task_fixture_normalizes_date_only_due_and_stable_id() {
        let raw: GoogleTask = serde_json::from_value(json!({
            "id": "task-123",
            "title": "Send proposal",
            "notes": "Attach the revised PDF",
            "status": "needsAction",
            "due": "2026-09-04T00:00:00.000Z",
            "updated": "2026-09-01T11:22:33.000Z"
        }))
        .unwrap();
        let task = normalize_google_task(&account("gmail"), "list/default", raw)
            .unwrap()
            .unwrap();
        assert_eq!(task.source, "google_tasks");
        assert_eq!(task.external_id, "task-123");
        assert_eq!(task.account, "account/one");
        assert_eq!(
            task.due_at.unwrap().to_rfc3339(),
            "2026-09-04T00:00:00+00:00"
        );
        assert!(!task.done);
        assert_eq!(
            decode_item_id(TASK_ID_PREFIX, &task.id).unwrap(),
            (
                "account/one".into(),
                "list/default".into(),
                "task-123".into()
            )
        );
    }

    #[test]
    fn microsoft_task_fixture_preserves_due_time() {
        let raw: MicrosoftTask = serde_json::from_value(json!({
            "id": "todo-9",
            "title": "Call Alex",
            "body": { "contentType": "text", "content": "Discuss launch" },
            "status": "completed",
            "createdDateTime": "2026-09-01T08:00:00Z",
            "dueDateTime": {
                "dateTime": "2026-09-03T16:45:00.000",
                "timeZone": "UTC"
            }
        }))
        .unwrap();
        let task = normalize_microsoft_task(&account("outlook"), "default-list", raw)
            .unwrap()
            .unwrap();
        assert_eq!(task.source, "microsoft_todo");
        assert_eq!(task.description, "Discuss launch");
        assert!(task.done);
        assert_eq!(
            task.due_at.unwrap().to_rfc3339(),
            "2026-09-03T16:45:00+00:00"
        );
    }

    #[test]
    fn google_all_day_event_fixture_keeps_exclusive_end_date() {
        let raw: GoogleEvent = serde_json::from_value(json!({
            "id": "holiday-1",
            "status": "confirmed",
            "summary": "Long weekend",
            "description": "Away",
            "start": { "date": "2026-09-05" },
            "end": { "date": "2026-09-08" }
        }))
        .unwrap();
        let event = normalize_google_event(&account("gmail"), "primary/id", false, raw)
            .unwrap()
            .unwrap();
        assert!(event.all_day);
        assert_eq!(event.start_at.to_rfc3339(), "2026-09-05T00:00:00+00:00");
        assert_eq!(event.end_at.to_rfc3339(), "2026-09-08T00:00:00+00:00");
        assert_eq!(event.calendar_name, "Person");
        assert_eq!(
            decode_calendar_id(&event.calendar_id).unwrap(),
            ("account/one".into(), "primary/id".into())
        );
    }

    #[test]
    fn microsoft_event_fixture_normalizes_utc_graph_values() {
        let raw: MicrosoftEvent = serde_json::from_value(json!({
            "id": "event-AAMk",
            "subject": "Design review",
            "body": {
                "contentType": "text",
                "content": "Review the complete sidebar and calendar flow"
            },
            "bodyPreview": "Review the complete sidebar",
            "start": { "dateTime": "2026-09-02T13:30:00.000", "timeZone": "UTC" },
            "end": { "dateTime": "2026-09-02T14:15:00.000", "timeZone": "UTC" },
            "isAllDay": false,
            "isCancelled": false
        }))
        .unwrap();
        let event = normalize_microsoft_event(&account("outlook"), "calendar-A", false, raw)
            .unwrap()
            .unwrap();
        assert_eq!(event.external_id, "event-AAMk");
        assert_eq!(
            event.description,
            "Review the complete sidebar and calendar flow"
        );
        assert_eq!(event.start_at.to_rfc3339(), "2026-09-02T13:30:00+00:00");
        assert_eq!(event.end_at.to_rfc3339(), "2026-09-02T14:15:00+00:00");
        assert!(!event.read_only);
    }

    #[test]
    fn url_allowlist_rejects_lookalikes_and_cross_api_paths() {
        let valid =
            Url::parse("https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=opaque")
                .unwrap();
        validate_api_url(ApiRoot::MicrosoftGraph, &valid).unwrap();

        for invalid in [
            "http://graph.microsoft.com/v1.0/me/events",
            "https://graph.microsoft.com.evil.example/v1.0/me/events",
            "https://graph.microsoft.com/beta/me/events",
            "https://user@graph.microsoft.com/v1.0/me/events",
            "https://www.googleapis.com/tasks/v1/users/@me/lists",
        ] {
            assert!(
                validate_api_url(ApiRoot::MicrosoftGraph, &Url::parse(invalid).unwrap()).is_err(),
                "accepted {invalid}"
            );
        }
    }

    #[test]
    fn dynamic_path_segments_cannot_change_the_allowlisted_origin() {
        let url = api_url(
            ApiRoot::GoogleCalendar,
            &[
                "calendars",
                "../../evil?redirect=https://example.com",
                "events",
            ],
        )
        .unwrap();
        assert_eq!(url.host_str(), Some("www.googleapis.com"));
        assert!(url.path().starts_with("/calendar/v3/calendars/"));
        assert!(url.query().is_none());
        assert!(url.path().contains("%2F"));
    }

    #[test]
    fn provider_routing_is_explicit() {
        assert_eq!(
            account_family(&account("gmail")),
            Some(GoaProviderFamily::Google)
        );
        assert_eq!(
            account_family(&account("microsoft365")),
            Some(GoaProviderFamily::Microsoft)
        );
        assert_eq!(account_family(&account("imap")), None);
    }
}
