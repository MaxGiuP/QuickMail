use std::{
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use chrono::{DateTime, Duration, Utc};
use quickmail_core::{
    Account, Address, CalendarEvent, DashboardSnapshot, DraftRecord, DraftSaved, MailAction,
    Mailbox, MailboxRole, MailboxSyncPage, Message, MessagePage, MessageQuery, MessageSummary,
    OutgoingMessage, SyncStatus, Task, ThreadConversation,
};
use rusqlite::{Connection, OptionalExtension, Row, Transaction, named_params, params};
use serde_json::Value;
use thiserror::Error;
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

const SCHEMA_VERSION: i64 = 8;
const MAX_PAGE_SIZE: u32 = 200;
const MAX_THREAD_MESSAGES: usize = 100;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("database error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("invalid data in database: {0}")]
    InvalidData(String),
    #[error("invalid page cursor")]
    InvalidCursor,
    #[error("resource not found")]
    NotFound,
    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("database worker stopped")]
    WorkerStopped,
}

#[derive(Clone)]
pub struct Database {
    jobs: mpsc::Sender<Job>,
}

type Job = Box<dyn FnOnce(&mut Repository) + Send + 'static>;

struct Repository {
    connection: Connection,
}

#[derive(Debug, Clone)]
pub(crate) struct PendingAgendaOperation {
    pub id: String,
    pub kind: String,
    pub account_id: String,
    pub payload: Value,
    pub attempted_at: Option<i64>,
}

impl Database {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StorageError> {
        Self::start(Repository::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self, StorageError> {
        Self::start(Repository::open_in_memory()?)
    }

    fn start(repository: Repository) -> Result<Self, StorageError> {
        let (jobs, mut receiver) = mpsc::channel::<Job>(128);
        std::thread::Builder::new()
            .name("quickmail-sqlite".into())
            .spawn(move || {
                let mut repository = repository;
                while let Some(job) = receiver.blocking_recv() {
                    job(&mut repository);
                }
            })
            .map_err(|error| StorageError::InvalidData(error.to_string()))?;
        Ok(Self { jobs })
    }

    async fn call<T, F>(&self, operation: F) -> Result<T, StorageError>
    where
        T: Send + 'static,
        F: FnOnce(&mut Repository) -> Result<T, StorageError> + Send + 'static,
    {
        let (result_sender, result_receiver) = oneshot::channel();
        self.jobs
            .send(Box::new(move |repository| {
                let _ = result_sender.send(operation(repository));
            }))
            .await
            .map_err(|_| StorageError::WorkerStopped)?;
        result_receiver
            .await
            .map_err(|_| StorageError::WorkerStopped)?
    }

    pub async fn journal_mode(&self) -> Result<String, StorageError> {
        self.call(|repository| repository.journal_mode()).await
    }

    pub async fn schema_version(&self) -> Result<i64, StorageError> {
        self.call(|repository| repository.schema_version()).await
    }

    pub async fn revision(&self) -> Result<u64, StorageError> {
        self.call(|repository| repository.revision()).await
    }

    pub async fn upsert_account(&self, account: &Account) -> Result<u64, StorageError> {
        let account = account.clone();
        self.call(move |repository| repository.upsert_account(&account))
            .await
    }

    pub async fn upsert_account_config(
        &self,
        account: &Account,
        config: Value,
    ) -> Result<u64, StorageError> {
        let account = account.clone();
        self.call(move |repository| repository.upsert_account_config(&account, &config))
            .await
    }

    pub async fn list_accounts(&self) -> Result<Vec<Account>, StorageError> {
        self.call(|repository| repository.list_accounts()).await
    }

    pub async fn update_account_counts(
        &self,
        account_id: &str,
        unread: u64,
        total: u64,
    ) -> Result<u64, StorageError> {
        let account_id = account_id.to_owned();
        self.call(move |repository| repository.update_account_counts(&account_id, unread, total))
            .await
    }

    pub async fn list_account_configs(&self) -> Result<Vec<(Account, Value)>, StorageError> {
        self.call(|repository| repository.list_account_configs())
            .await
    }

    pub async fn account_config(
        &self,
        account_id: &str,
    ) -> Result<Option<(Account, Value)>, StorageError> {
        let account_id = account_id.to_owned();
        self.call(move |repository| repository.account_config(&account_id))
            .await
    }

    pub async fn set_account_auth_state(
        &self,
        account_id: &str,
        state: &str,
        error: Option<&str>,
    ) -> Result<u64, StorageError> {
        let account_id = account_id.to_owned();
        let state = state.to_owned();
        let error = error.map(str::to_owned);
        self.call(move |repository| {
            repository.set_account_auth_state(&account_id, &state, error.as_deref())
        })
        .await
    }

    pub async fn account_auth_state(
        &self,
        account_id: &str,
    ) -> Result<Option<(String, Option<String>)>, StorageError> {
        let account_id = account_id.to_owned();
        self.call(move |repository| repository.account_auth_state(&account_id))
            .await
    }

    pub async fn remove_account(&self, id: &str) -> Result<u64, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.remove_account(&id))
            .await
    }

    pub async fn upsert_mailboxes(&self, mailboxes: &[Mailbox]) -> Result<u64, StorageError> {
        let mailboxes = mailboxes.to_vec();
        self.call(move |repository| repository.upsert_mailboxes(&mailboxes))
            .await
    }

    pub async fn list_mailboxes(&self, account_id: &str) -> Result<Vec<Mailbox>, StorageError> {
        let account_id = account_id.to_owned();
        self.call(move |repository| repository.list_mailboxes(&account_id))
            .await
    }

    pub async fn mailbox_sync_cursor(
        &self,
        account_id: &str,
        mailbox_id: &str,
    ) -> Result<Option<String>, StorageError> {
        let account_id = account_id.to_owned();
        let mailbox_id = mailbox_id.to_owned();
        self.call(move |repository| repository.mailbox_sync_cursor(&account_id, &mailbox_id))
            .await
    }

    pub async fn apply_mailbox_sync_page(
        &self,
        account_id: &str,
        mailbox_id: &str,
        page: &MailboxSyncPage,
    ) -> Result<u64, StorageError> {
        let account_id = account_id.to_owned();
        let mailbox_id = mailbox_id.to_owned();
        let page = page.clone();
        self.call(move |repository| {
            repository.apply_mailbox_sync_page(&account_id, &mailbox_id, &page)
        })
        .await
    }

    pub async fn upsert_messages(&self, messages: &[Message]) -> Result<u64, StorageError> {
        let messages = messages.to_vec();
        self.call(move |repository| repository.upsert_messages(&messages))
            .await
    }

    pub async fn upsert_message_summaries(
        &self,
        messages: &[MessageSummary],
    ) -> Result<u64, StorageError> {
        let messages = messages.to_vec();
        self.call(move |repository| repository.upsert_message_summaries(&messages))
            .await
    }

    pub async fn list_messages(&self, query: &MessageQuery) -> Result<MessagePage, StorageError> {
        let query = query.clone();
        self.call(move |repository| repository.list_messages(&query))
            .await
    }

    pub async fn thread_metadata_backfill_ids(
        &self,
        account_id: &str,
        mailbox_id: &str,
        limit: u32,
    ) -> Result<Vec<String>, StorageError> {
        let account_id = account_id.to_owned();
        let mailbox_id = mailbox_id.to_owned();
        self.call(move |repository| {
            repository.thread_metadata_backfill_ids(&account_id, &mailbox_id, limit)
        })
        .await
    }

    pub async fn get_message(&self, id: &str) -> Result<Option<Message>, StorageError> {
        Ok(self
            .get_cached_message(id)
            .await?
            .map(|(message, _body_loaded)| message))
    }

    pub async fn get_cached_message(
        &self,
        id: &str,
    ) -> Result<Option<(Message, bool)>, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.get_cached_message(&id))
            .await
    }

    #[cfg(test)]
    pub(crate) async fn mark_cached_html_stale_for_test(
        &self,
        id: &str,
    ) -> Result<(), StorageError> {
        let id = id.to_owned();
        self.call(move |repository| {
            repository.connection.execute(
                "UPDATE messages SET body_loaded=0 WHERE id=?1 AND body_html IS NOT NULL",
                [id],
            )?;
            Ok(())
        })
        .await
    }

    pub async fn get_thread(&self, message_id: &str) -> Result<ThreadConversation, StorageError> {
        let message_id = message_id.to_owned();
        self.call(move |repository| repository.get_thread(&message_id))
            .await
    }

    pub async fn apply_mail_action(
        &self,
        action: &MailAction,
    ) -> Result<(String, u64), StorageError> {
        let action = action.clone();
        self.call(move |repository| repository.apply_mail_action(&action))
            .await
    }

    pub async fn finish_operation(
        &self,
        operation_id: &str,
        result: Result<(), String>,
    ) -> Result<(), StorageError> {
        let operation_id = operation_id.to_owned();
        self.call(move |repository| repository.finish_operation(&operation_id, result))
            .await
    }

    pub async fn finish_mail_action(
        &self,
        operation_id: &str,
        action: &MailAction,
        result: Result<(), String>,
    ) -> Result<u64, StorageError> {
        let operation_id = operation_id.to_owned();
        let action = action.clone();
        self.call(move |repository| repository.finish_mail_action(&operation_id, &action, result))
            .await
    }

    pub async fn queue_outgoing(
        &self,
        message: &OutgoingMessage,
    ) -> Result<(String, u64), StorageError> {
        let message = message.clone();
        self.call(move |repository| repository.queue_outgoing(&message))
            .await
    }

    pub async fn save_draft(
        &self,
        draft_id: Option<&str>,
        message: &OutgoingMessage,
    ) -> Result<(DraftSaved, u64), StorageError> {
        let draft_id = draft_id.map(str::to_owned);
        let message = message.clone();
        self.call(move |repository| repository.save_draft(draft_id.as_deref(), &message))
            .await
    }

    pub async fn list_drafts(
        &self,
        account_id: Option<&str>,
    ) -> Result<Vec<DraftRecord>, StorageError> {
        let account_id = account_id.map(str::to_owned);
        self.call(move |repository| repository.list_drafts(account_id.as_deref()))
            .await
    }

    pub async fn get_draft(&self, draft_id: &str) -> Result<DraftRecord, StorageError> {
        let draft_id = draft_id.to_owned();
        self.call(move |repository| repository.get_draft(&draft_id))
            .await
    }

    pub async fn delete_draft(&self, draft_id: &str) -> Result<u64, StorageError> {
        let draft_id = draft_id.to_owned();
        self.call(move |repository| repository.delete_draft(&draft_id))
            .await
    }

    pub async fn list_tasks(&self, include_done: bool) -> Result<Vec<Task>, StorageError> {
        self.call(move |repository| repository.list_tasks(include_done))
            .await
    }

    pub async fn get_task(&self, id: &str) -> Result<Task, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.get_task(&id)).await
    }

    pub async fn upsert_task(&self, task: &Task) -> Result<u64, StorageError> {
        let task = task.clone();
        self.call(move |repository| repository.upsert_task(&task))
            .await
    }

    pub async fn complete_task(&self, id: &str, done: bool) -> Result<u64, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.complete_task(&id, done))
            .await
    }

    pub async fn delete_task(&self, id: &str) -> Result<u64, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.delete_task(&id))
            .await
    }

    pub async fn upsert_events(&self, events: &[CalendarEvent]) -> Result<u64, StorageError> {
        let events = events.to_vec();
        self.call(move |repository| repository.upsert_events(&events))
            .await
    }

    pub async fn delete_event(&self, id: &str) -> Result<u64, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.delete_event(&id))
            .await
    }

    pub async fn get_event(&self, id: &str) -> Result<CalendarEvent, StorageError> {
        let id = id.to_owned();
        self.call(move |repository| repository.get_event(&id)).await
    }

    pub async fn replace_remote_agenda(
        &self,
        account_id: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        tasks: &[Task],
        events: &[CalendarEvent],
    ) -> Result<u64, StorageError> {
        let account_id = account_id.to_owned();
        let tasks = tasks.to_vec();
        let events = events.to_vec();
        self.call(move |repository| {
            repository.replace_remote_agenda(&account_id, start, end, &tasks, &events)
        })
        .await
    }

    pub async fn queue_agenda_operation(
        &self,
        kind: &str,
        account_id: &str,
        payload: &Value,
    ) -> Result<(String, u64), StorageError> {
        let kind = kind.to_owned();
        let account_id = account_id.to_owned();
        let payload = payload.clone();
        self.call(move |repository| repository.queue_agenda_operation(&kind, &account_id, &payload))
            .await
    }

    pub(crate) async fn list_pending_agenda_operations(
        &self,
        account_id: Option<&str>,
    ) -> Result<Vec<PendingAgendaOperation>, StorageError> {
        let account_id = account_id.map(str::to_owned);
        self.call(move |repository| {
            repository.list_pending_agenda_operations(account_id.as_deref())
        })
        .await
    }

    pub async fn defer_operation(
        &self,
        operation_id: &str,
        error: &str,
    ) -> Result<(), StorageError> {
        let operation_id = operation_id.to_owned();
        let error = error.to_owned();
        self.call(move |repository| repository.defer_operation(&operation_id, &error))
            .await
    }

    pub async fn commit_agenda_task_upsert(
        &self,
        operation_id: &str,
        task: &Task,
    ) -> Result<u64, StorageError> {
        let operation_id = operation_id.to_owned();
        let task = task.clone();
        self.call(move |repository| repository.commit_agenda_task_upsert(&operation_id, &task))
            .await
    }

    pub async fn commit_agenda_task_delete(
        &self,
        operation_id: &str,
        task_id: &str,
    ) -> Result<u64, StorageError> {
        let operation_id = operation_id.to_owned();
        let task_id = task_id.to_owned();
        self.call(move |repository| repository.commit_agenda_task_delete(&operation_id, &task_id))
            .await
    }

    pub async fn commit_agenda_event_upsert(
        &self,
        operation_id: &str,
        event: &CalendarEvent,
    ) -> Result<u64, StorageError> {
        let operation_id = operation_id.to_owned();
        let event = event.clone();
        self.call(move |repository| repository.commit_agenda_event_upsert(&operation_id, &event))
            .await
    }

    pub async fn commit_agenda_event_delete(
        &self,
        operation_id: &str,
        event_id: &str,
    ) -> Result<u64, StorageError> {
        let operation_id = operation_id.to_owned();
        let event_id = event_id.to_owned();
        self.call(move |repository| repository.commit_agenda_event_delete(&operation_id, &event_id))
            .await
    }

    pub async fn list_events(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<CalendarEvent>, StorageError> {
        self.call(move |repository| repository.list_events(start, end))
            .await
    }

    pub async fn dashboard_snapshot(&self) -> Result<DashboardSnapshot, StorageError> {
        self.call(|repository| repository.dashboard_snapshot())
            .await
    }

    pub async fn seed_demo(&self) -> Result<(), StorageError> {
        self.call(Repository::seed_demo).await
    }
}

impl Repository {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StorageError> {
        let path = path.as_ref();
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            ensure_private_directory(parent)?;
        }
        if path.exists() {
            let metadata = std::fs::symlink_metadata(path)
                .map_err(|error| StorageError::InvalidData(error.to_string()))?;
            if !metadata.file_type().is_file() || metadata.uid() != current_uid() {
                return Err(StorageError::InvalidData(format!(
                    "refusing database not owned by current user: {}",
                    path.display()
                )));
            }
        } else {
            std::fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(path)
                .map_err(|error| StorageError::InvalidData(error.to_string()))?;
        }
        let connection = Connection::open(path)?;
        let repository = Self::from_connection(connection, false)?;
        secure_database_files(path)?;
        Ok(repository)
    }

    pub fn open_in_memory() -> Result<Self, StorageError> {
        Self::from_connection(Connection::open_in_memory()?, true)
    }

    fn from_connection(connection: Connection, in_memory: bool) -> Result<Self, StorageError> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        if !in_memory {
            connection.pragma_update(None, "journal_mode", "WAL")?;
        }
        migrate(&connection)?;
        Ok(Self { connection })
    }

    fn journal_mode(&self) -> Result<String, StorageError> {
        let connection = &self.connection;
        Ok(connection.pragma_query_value(None, "journal_mode", |row| row.get(0))?)
    }

    fn schema_version(&self) -> Result<i64, StorageError> {
        let connection = &self.connection;
        Ok(connection.pragma_query_value(None, "user_version", |row| row.get(0))?)
    }

    fn revision(&self) -> Result<u64, StorageError> {
        let connection = &self.connection;
        read_revision(connection)
    }

    fn upsert_account(&mut self, account: &Account) -> Result<u64, StorageError> {
        self.upsert_account_config(account, &Value::Object(Default::default()))
    }

    fn upsert_account_config(
        &mut self,
        account: &Account,
        config: &Value,
    ) -> Result<u64, StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO accounts
             (id, address, display_name, provider, protocol, host, unread, total, enabled, config_json, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             ON CONFLICT(id) DO UPDATE SET
               address=excluded.address, display_name=excluded.display_name,
               provider=excluded.provider, protocol=excluded.protocol, host=excluded.host,
               unread=excluded.unread, total=excluded.total, enabled=excluded.enabled,
               config_json=excluded.config_json, updated_at=excluded.updated_at",
            params![
                account.id,
                account.address,
                account.display_name,
                account.provider,
                account.protocol,
                account.host,
                account.unread,
                account.total,
                account.enabled,
                serde_json::to_string(config)?,
                Utc::now().timestamp_millis(),
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn list_accounts(&self) -> Result<Vec<Account>, StorageError> {
        let connection = &self.connection;
        let mut statement = connection.prepare_cached(
            "SELECT id, address, display_name, provider, protocol, host, unread, total, enabled
             FROM accounts ORDER BY address COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(Account {
                id: row.get(0)?,
                address: row.get(1)?,
                display_name: row.get(2)?,
                provider: row.get(3)?,
                protocol: row.get(4)?,
                host: row.get(5)?,
                unread: row.get(6)?,
                total: row.get(7)?,
                enabled: row.get(8)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn update_account_counts(
        &mut self,
        account_id: &str,
        unread: u64,
        total: u64,
    ) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        if transaction.execute(
            "UPDATE accounts SET unread=?2, total=?3, updated_at=?4 WHERE id=?1",
            params![account_id, unread, total, Utc::now().timestamp_millis()],
        )? == 0
        {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn list_account_configs(&self) -> Result<Vec<(Account, Value)>, StorageError> {
        let mut statement = self.connection.prepare_cached(
            "SELECT id, address, display_name, provider, protocol, host, unread, total, enabled,
                    config_json FROM accounts ORDER BY address COLLATE NOCASE",
        )?;
        let rows = statement.query_map([], account_config_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn account_config(&self, account_id: &str) -> Result<Option<(Account, Value)>, StorageError> {
        self.connection
            .query_row(
                "SELECT id, address, display_name, provider, protocol, host, unread, total, enabled,
                        config_json FROM accounts WHERE id=?1",
                [account_id],
                account_config_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    fn set_account_auth_state(
        &mut self,
        account_id: &str,
        state: &str,
        error: Option<&str>,
    ) -> Result<u64, StorageError> {
        if !matches!(state, "ready" | "needs_auth" | "error") {
            return Err(StorageError::InvalidData(
                "invalid account auth state".into(),
            ));
        }
        let transaction = self.connection.transaction()?;
        if transaction.execute(
            "UPDATE accounts SET auth_state=?2, auth_error=?3, updated_at=?4 WHERE id=?1",
            params![account_id, state, error, Utc::now().timestamp_millis()],
        )? == 0
        {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn account_auth_state(
        &self,
        account_id: &str,
    ) -> Result<Option<(String, Option<String>)>, StorageError> {
        self.connection
            .query_row(
                "SELECT auth_state, auth_error FROM accounts WHERE id=?1",
                [account_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(Into::into)
    }

    fn remove_account(&mut self, id: &str) -> Result<u64, StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        remove_account_operations(&transaction, id)?;
        transaction.execute("DELETE FROM tasks WHERE account=?1", [id])?;
        transaction.execute(
            "DELETE FROM events
             WHERE substr(calendar_id, 1, length(?1) + 1) = ?1 || ':'",
            [id],
        )?;
        if transaction.execute("DELETE FROM accounts WHERE id=?1", [id])? == 0 {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn upsert_mailboxes(&mut self, mailboxes: &[Mailbox]) -> Result<u64, StorageError> {
        if mailboxes.is_empty() {
            return self.revision();
        }
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO mailboxes (id, account_id, name, role, unread, total)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(account_id, id) DO UPDATE SET
                  name=excluded.name, role=excluded.role, unread=excluded.unread,
                  total=excluded.total",
            )?;
            for mailbox in mailboxes {
                statement.execute(params![
                    mailbox.id,
                    mailbox.account_id,
                    mailbox.name,
                    mailbox.role.map(mailbox_role_name),
                    mailbox.unread,
                    mailbox.total,
                ])?;
            }
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn list_mailboxes(&self, account_id: &str) -> Result<Vec<Mailbox>, StorageError> {
        let connection = &self.connection;
        let mut statement = connection.prepare_cached(
            "SELECT id, account_id, name, role, unread, total FROM mailboxes
             WHERE account_id=?1 ORDER BY
               CASE role WHEN 'inbox' THEN 0 WHEN 'drafts' THEN 1 WHEN 'sent' THEN 2
                 WHEN 'archive' THEN 3 WHEN 'spam' THEN 4 WHEN 'trash' THEN 5 ELSE 6 END,
               name COLLATE NOCASE",
        )?;
        let rows = statement.query_map([account_id], |row| {
            let role: Option<String> = row.get(3)?;
            Ok(Mailbox {
                id: row.get(0)?,
                account_id: row.get(1)?,
                name: row.get(2)?,
                role: role.as_deref().map(parse_mailbox_role),
                unread: row.get(4)?,
                total: row.get(5)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn mailbox_sync_cursor(
        &self,
        account_id: &str,
        mailbox_id: &str,
    ) -> Result<Option<String>, StorageError> {
        self.connection
            .query_row(
                "SELECT cursor FROM mailbox_sync_state
                 WHERE account_id=?1 AND mailbox_id=?2",
                params![account_id, mailbox_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    /// Commits summaries and their provider cursor together. Advancing the
    /// cursor without the corresponding rows would permanently skip mail after
    /// a crash, while a failed transaction safely causes the page to be fetched
    /// again on the next refresh.
    fn apply_mailbox_sync_page(
        &mut self,
        account_id: &str,
        mailbox_id: &str,
        page: &MailboxSyncPage,
    ) -> Result<u64, StorageError> {
        for message in &page.messages {
            if message.account_id != account_id
                || message.mailbox_id.as_deref() != Some(mailbox_id)
                || !quickmail_core::is_normalized_message_id(account_id, &message.id)
            {
                return Err(StorageError::InvalidData(
                    "mailbox sync page contains a message outside its account or mailbox".into(),
                ));
            }
        }
        for message_id in &page.removed_message_ids {
            if !quickmail_core::is_normalized_message_id(account_id, message_id)
                || page
                    .messages
                    .iter()
                    .any(|message| message.id == *message_id)
            {
                return Err(StorageError::InvalidData(
                    "mailbox sync removal is outside its account or also returned as present"
                        .into(),
                ));
            }
        }
        if page
            .cursor
            .as_ref()
            .is_some_and(|cursor| cursor.is_empty() || cursor.len() > 1024 || cursor.contains('\0'))
        {
            return Err(StorageError::InvalidData(
                "mailbox sync cursor is invalid".into(),
            ));
        }
        if !page.reset
            && page.messages.is_empty()
            && page.removed_message_ids.is_empty()
            && page.cursor.is_none()
        {
            return self.revision();
        }

        let transaction = self.connection.transaction()?;
        let mailbox_exists = transaction
            .query_row(
                "SELECT 1 FROM mailboxes WHERE account_id=?1 AND id=?2",
                params![account_id, mailbox_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !mailbox_exists {
            return Err(StorageError::NotFound);
        }

        // Validate every existing removal target against the scoped mailbox
        // before this transaction deletes either individual rows or a reset
        // generation. Missing rows are already in the requested end state.
        for message_id in &page.removed_message_ids {
            let location = transaction
                .query_row(
                    "SELECT account_id, mailbox_id FROM messages WHERE id=?1",
                    [message_id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                )
                .optional()?;
            if location
                .as_ref()
                .is_some_and(|(stored_account, stored_mailbox)| {
                    stored_account != account_id || stored_mailbox.as_deref() != Some(mailbox_id)
                })
            {
                return Err(StorageError::InvalidData(
                    "mailbox sync removal targets a different account or mailbox".into(),
                ));
            }
        }

        if page.reset {
            transaction.execute(
                "DELETE FROM messages WHERE account_id=?1 AND mailbox_id=?2",
                params![account_id, mailbox_id],
            )?;
            transaction.execute(
                "DELETE FROM mailbox_sync_state WHERE account_id=?1 AND mailbox_id=?2",
                params![account_id, mailbox_id],
            )?;
        }

        {
            let mut statement = transaction.prepare_cached(
                "DELETE FROM messages WHERE id=?1 AND account_id=?2 AND mailbox_id=?3",
            )?;
            for message_id in &page.removed_message_ids {
                statement.execute(params![message_id, account_id, mailbox_id])?;
            }
        }

        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO messages
                 (id, account_id, mailbox_id, thread_id, subject, author_name, author_address,
                  timestamp_ms, is_read, starred, snippet, has_attachments, labels_json,
                  provider_data_json, to_json, cc_json, bcc_json, body_text, body_html,
                  attachments_json, body_loaded, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         ?14, '[]', '[]', '[]', NULL, NULL, '[]', 0, ?15)
                 ON CONFLICT(id) DO UPDATE SET
                  account_id=excluded.account_id, mailbox_id=excluded.mailbox_id,
                  thread_id=excluded.thread_id, subject=excluded.subject,
                  author_name=excluded.author_name, author_address=excluded.author_address,
                  timestamp_ms=excluded.timestamp_ms, is_read=excluded.is_read,
                  starred=excluded.starred, snippet=excluded.snippet,
                  has_attachments=excluded.has_attachments, labels_json=excluded.labels_json,
                  provider_data_json=excluded.provider_data_json,
                  updated_at=excluded.updated_at",
            )?;
            let now = Utc::now().timestamp_millis();
            for message in &page.messages {
                let author = message.author.as_ref();
                statement.execute(params![
                    message.id,
                    message.account_id,
                    message.mailbox_id,
                    message.thread_id,
                    message.subject,
                    author.map(|author| author.name.as_str()),
                    author.map(|author| author.address.as_str()),
                    message.timestamp.timestamp_millis(),
                    message.read,
                    message.starred,
                    message.snippet,
                    message.has_attachments,
                    serde_json::to_string(&message.labels)?,
                    serde_json::to_string(&message.provider_data)?,
                    now,
                ])?;
            }
        }

        if let Some(cursor) = &page.cursor {
            transaction.execute(
                "INSERT INTO mailbox_sync_state
                 (account_id, mailbox_id, cursor, updated_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(account_id, mailbox_id) DO UPDATE SET
                  cursor=excluded.cursor, updated_at=excluded.updated_at",
                params![
                    account_id,
                    mailbox_id,
                    cursor,
                    Utc::now().timestamp_millis()
                ],
            )?;
        }

        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    /// Inserts a sync batch in one transaction. Message bodies are persisted but
    /// deliberately excluded from list and dashboard queries.
    fn upsert_messages(&mut self, messages: &[Message]) -> Result<u64, StorageError> {
        self.upsert_messages_with_body_state(messages, true)
    }

    fn upsert_messages_with_body_state(
        &mut self,
        messages: &[Message],
        body_loaded: bool,
    ) -> Result<u64, StorageError> {
        if messages.is_empty() {
            return self.revision();
        }
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO messages
                 (id, account_id, mailbox_id, thread_id, subject, author_name, author_address,
                  timestamp_ms, is_read, starred, snippet, has_attachments, labels_json,
                  provider_data_json, to_json, cc_json, bcc_json, body_text, body_html,
                  attachments_json, body_loaded, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
                 ON CONFLICT(id) DO UPDATE SET
                  account_id=excluded.account_id, mailbox_id=excluded.mailbox_id,
                  thread_id=excluded.thread_id, subject=excluded.subject,
                  author_name=excluded.author_name, author_address=excluded.author_address,
                  timestamp_ms=excluded.timestamp_ms, is_read=excluded.is_read,
                  starred=excluded.starred, snippet=excluded.snippet,
                  has_attachments=excluded.has_attachments, labels_json=excluded.labels_json,
                  provider_data_json=excluded.provider_data_json,
                  to_json=CASE WHEN excluded.body_loaded=0
                    THEN messages.to_json ELSE excluded.to_json END,
                  cc_json=CASE WHEN excluded.body_loaded=0
                    THEN messages.cc_json ELSE excluded.cc_json END,
                  bcc_json=CASE WHEN excluded.body_loaded=0
                    THEN messages.bcc_json ELSE excluded.bcc_json END,
                  body_text=CASE WHEN excluded.body_loaded=0
                    THEN messages.body_text ELSE excluded.body_text END,
                  body_html=CASE WHEN excluded.body_loaded=0
                    THEN messages.body_html ELSE excluded.body_html END,
                  attachments_json=CASE WHEN excluded.body_loaded=0
                    THEN messages.attachments_json ELSE excluded.attachments_json END,
                  body_loaded=MAX(messages.body_loaded, excluded.body_loaded),
                  updated_at=excluded.updated_at",
            )?;
            let now = Utc::now().timestamp_millis();
            for message in messages {
                if !quickmail_core::is_normalized_message_id(
                    &message.summary.account_id,
                    &message.summary.id,
                ) {
                    return Err(StorageError::InvalidData(format!(
                        "message id {} is not namespaced by account {}",
                        message.summary.id, message.summary.account_id
                    )));
                }
                let author = message.summary.author.as_ref();
                statement.execute(params![
                    message.summary.id,
                    message.summary.account_id,
                    message.summary.mailbox_id,
                    message.summary.thread_id,
                    message.summary.subject,
                    author.map(|author| author.name.as_str()),
                    author.map(|author| author.address.as_str()),
                    message.summary.timestamp.timestamp_millis(),
                    message.summary.read,
                    message.summary.starred,
                    message.summary.snippet,
                    message.summary.has_attachments,
                    serde_json::to_string(&message.summary.labels)?,
                    serde_json::to_string(&message.summary.provider_data)?,
                    serde_json::to_string(&message.to)?,
                    serde_json::to_string(&message.cc)?,
                    serde_json::to_string(&message.bcc)?,
                    message.body_text,
                    message.body_html,
                    serde_json::to_string(&message.attachments)?,
                    body_loaded,
                    now,
                ])?;
            }
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn upsert_message_summaries(
        &mut self,
        summaries: &[MessageSummary],
    ) -> Result<u64, StorageError> {
        let messages = summaries
            .iter()
            .cloned()
            .map(|summary| Message {
                summary,
                to: vec![],
                cc: vec![],
                bcc: vec![],
                body_text: None,
                body_html: None,
                attachments: vec![],
            })
            .collect::<Vec<_>>();
        self.upsert_messages_with_body_state(&messages, false)
    }

    fn list_messages(&self, query: &MessageQuery) -> Result<MessagePage, StorageError> {
        let limit = query.limit.clamp(1, MAX_PAGE_SIZE);
        let (cursor_timestamp, cursor_id) = query
            .cursor
            .as_deref()
            .map(decode_cursor)
            .transpose()?
            .map_or((None, None), |(timestamp, id)| (Some(timestamp), Some(id)));
        let search = query
            .search
            .as_deref()
            .filter(|value| !value.trim().is_empty());

        let connection = &self.connection;
        let mut statement = connection.prepare_cached(
            "SELECT id, account_id, mailbox_id, thread_id, subject, author_name, author_address,
                    timestamp_ms, is_read, starred, snippet, has_attachments, labels_json,
                    provider_data_json
             FROM messages
             WHERE (:account_id IS NULL OR account_id = :account_id)
               AND (:mailbox_id IS NULL OR mailbox_id = :mailbox_id)
               AND (:unread_only = 0 OR is_read = 0)
               AND (:cursor_timestamp IS NULL OR timestamp_ms < :cursor_timestamp
                    OR (timestamp_ms = :cursor_timestamp AND id < :cursor_id))
               AND (:search IS NULL OR id IN
                    (SELECT message_id FROM messages_fts WHERE messages_fts MATCH :search))
             ORDER BY timestamp_ms DESC, id DESC
             LIMIT :limit",
        )?;
        let rows = statement.query_map(
            named_params! {
                ":account_id": query.account_id,
                ":mailbox_id": query.mailbox_id,
                ":unread_only": query.unread_only,
                ":cursor_timestamp": cursor_timestamp,
                ":cursor_id": cursor_id,
                ":search": search,
                ":limit": limit + 1,
            },
            message_summary_from_row,
        )?;
        let mut messages = rows.collect::<Result<Vec<_>, _>>()?;
        let has_more = messages.len() > limit as usize;
        messages.truncate(limit as usize);
        let next_cursor = has_more
            .then(|| messages.last().map(encode_cursor))
            .flatten();
        Ok(MessagePage {
            messages,
            next_cursor,
        })
    }

    fn thread_metadata_backfill_ids(
        &self,
        account_id: &str,
        mailbox_id: &str,
        limit: u32,
    ) -> Result<Vec<String>, StorageError> {
        let mut statement = self.connection.prepare_cached(
            "SELECT id FROM messages
             WHERE account_id=?1 AND mailbox_id=?2
               AND (thread_id IS NULL OR TRIM(thread_id)='')
             ORDER BY updated_at ASC, id ASC
             LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![account_id, mailbox_id, limit.clamp(1, MAX_PAGE_SIZE)],
            |row| row.get(0),
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn get_cached_message(&self, id: &str) -> Result<Option<(Message, bool)>, StorageError> {
        let connection = &self.connection;
        let mut statement = connection.prepare_cached(
            "SELECT id, account_id, mailbox_id, thread_id, subject, author_name, author_address,
                    timestamp_ms, is_read, starred, snippet, has_attachments, labels_json,
                    provider_data_json, to_json, cc_json, bcc_json, body_text, body_html,
                    attachments_json, body_loaded
             FROM messages WHERE id = ?1",
        )?;
        let message = statement
            .query_row([id], cached_message_from_row)
            .optional()?;
        Ok(message)
    }

    fn get_thread(&self, message_id: &str) -> Result<ThreadConversation, StorageError> {
        let (anchor, _) = self
            .get_cached_message(message_id)?
            .ok_or(StorageError::NotFound)?;
        let Some(thread_id) = anchor
            .summary
            .thread_id
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        else {
            return Ok(ThreadConversation {
                id: anchor.summary.id.clone(),
                messages: vec![anchor.summary],
                truncated: false,
            });
        };

        // One IMAP message can be cached under multiple mailbox-scoped UIDs
        // (notably Gmail's INBOX and All Mail). Collapse those physical copies
        // by RFC Message-ID before applying the response bound. Ranking the
        // requested copy first also guarantees that an old selected message is
        // retained when the conversation has more than the response limit.
        let mut statement = self.connection.prepare_cached(
            "WITH ranked AS (
               SELECT id, account_id, mailbox_id, thread_id, subject, author_name,
                      author_address, timestamp_ms, is_read, starred, snippet,
                      has_attachments, labels_json, provider_data_json,
                      ROW_NUMBER() OVER (
                        PARTITION BY COALESCE(
                          NULLIF(TRIM(CAST(json_extract(
                            provider_data_json, '$.messageId') AS TEXT)), ''), id)
                        ORDER BY CASE WHEN id=?3 THEN 0 ELSE 1 END,
                                 timestamp_ms DESC, id DESC
                      ) AS copy_rank
               FROM messages
               WHERE account_id=?1 AND thread_id=?2
             )
             SELECT id, account_id, mailbox_id, thread_id, subject, author_name,
                    author_address, timestamp_ms, is_read, starred, snippet,
                    has_attachments, labels_json, provider_data_json
             FROM ranked
             WHERE copy_rank=1
             ORDER BY CASE WHEN id=?3 THEN 0 ELSE 1 END, timestamp_ms DESC, id DESC
             LIMIT ?4",
        )?;
        let rows = statement.query_map(
            params![
                anchor.summary.account_id,
                thread_id,
                message_id,
                (MAX_THREAD_MESSAGES + 1) as i64
            ],
            message_summary_from_row,
        )?;
        let mut messages = rows.collect::<Result<Vec<_>, _>>()?;
        let truncated = messages.len() > MAX_THREAD_MESSAGES;
        messages.truncate(MAX_THREAD_MESSAGES);
        messages.sort_by(|left, right| {
            left.timestamp
                .cmp(&right.timestamp)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(ThreadConversation {
            id: thread_id.to_owned(),
            messages,
            truncated,
        })
    }

    fn apply_mail_action(&mut self, action: &MailAction) -> Result<(String, u64), StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        validate_mail_action(action)?;
        let operation_id = Uuid::new_v4().to_string();
        transaction.execute(
            "INSERT INTO operations (id, kind, payload_json, state, created_at)
             VALUES (?1, 'mail_action', ?2, 'pending', ?3)",
            params![
                operation_id,
                serde_json::to_string(action)?,
                Utc::now().timestamp_millis()
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok((operation_id, revision))
    }

    fn finish_operation(
        &mut self,
        operation_id: &str,
        result: Result<(), String>,
    ) -> Result<(), StorageError> {
        let (state, error) = match result {
            Ok(()) => ("succeeded", None),
            Err(error) => ("failed", Some(error)),
        };
        let changed = self.connection.execute(
            "UPDATE operations SET state=?2, attempted_at=?3, last_error=?4 WHERE id=?1",
            params![operation_id, state, Utc::now().timestamp_millis(), error],
        )?;
        if changed == 0 {
            return Err(StorageError::NotFound);
        }
        Ok(())
    }

    fn defer_operation(&mut self, operation_id: &str, error: &str) -> Result<(), StorageError> {
        let changed = self.connection.execute(
            "UPDATE operations
             SET state='pending', attempted_at=?2, last_error=?3
             WHERE id=?1 AND state='pending' AND kind LIKE 'agenda_%'",
            params![operation_id, Utc::now().timestamp_millis(), error],
        )?;
        if changed == 0 {
            return Err(StorageError::NotFound);
        }
        Ok(())
    }

    fn finish_mail_action(
        &mut self,
        operation_id: &str,
        action: &MailAction,
        result: Result<(), String>,
    ) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        let succeeded = result.is_ok();
        let (state, error) = match result {
            Ok(()) => ("succeeded", None),
            Err(error) => ("failed", Some(error)),
        };
        let changed = transaction.execute(
            "UPDATE operations SET state=?2, attempted_at=?3, last_error=?4 WHERE id=?1",
            params![operation_id, state, Utc::now().timestamp_millis(), error],
        )?;
        if changed == 0 {
            return Err(StorageError::NotFound);
        }

        let revision = if succeeded {
            apply_action_locally(&transaction, action)?;
            bump_revision(&transaction)?
        } else {
            read_revision(&transaction)?
        };
        transaction.commit()?;
        Ok(revision)
    }

    fn queue_outgoing(&mut self, message: &OutgoingMessage) -> Result<(String, u64), StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        let operation_id = Uuid::new_v4().to_string();
        // The provider receives the full message directly. Operation history only
        // needs ownership metadata, so do not duplicate recipients or message
        // bodies in a long-lived diagnostic row.
        let payload = serde_json::json!({"accountId": message.account_id.as_str()});
        transaction.execute(
            "INSERT INTO operations (id, kind, payload_json, state, created_at)
             VALUES (?1, 'mail_send', ?2, 'pending', ?3)",
            params![
                operation_id,
                serde_json::to_string(&payload)?,
                Utc::now().timestamp_millis()
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok((operation_id, revision))
    }

    fn queue_agenda_operation(
        &mut self,
        kind: &str,
        account_id: &str,
        payload: &Value,
    ) -> Result<(String, u64), StorageError> {
        const KINDS: &[&str] = &[
            "agenda_task_create",
            "agenda_task_update",
            "agenda_task_complete",
            "agenda_task_delete",
            "agenda_event_create",
            "agenda_event_update",
            "agenda_event_delete",
        ];
        if !KINDS.contains(&kind) || account_id.trim().is_empty() || !payload.is_object() {
            return Err(StorageError::InvalidData(
                "invalid remote agenda operation".into(),
            ));
        }

        let mut payload = payload.clone();
        payload["accountId"] = Value::String(account_id.to_owned());
        let transaction = self.connection.transaction()?;
        let operation_id = Uuid::new_v4().to_string();
        transaction.execute(
            "INSERT INTO operations (id, kind, payload_json, state, created_at)
             VALUES (?1, ?2, ?3, 'pending', ?4)",
            params![
                operation_id,
                kind,
                serde_json::to_string(&payload)?,
                Utc::now().timestamp_millis()
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok((operation_id, revision))
    }

    fn list_pending_agenda_operations(
        &self,
        account_id: Option<&str>,
    ) -> Result<Vec<PendingAgendaOperation>, StorageError> {
        const MAX_RECOVERY_OPERATIONS: usize = 128;
        let mut statement = self.connection.prepare_cached(
            "SELECT id, kind, payload_json, attempted_at
             FROM operations
             WHERE state='pending' AND kind LIKE 'agenda_%'
               AND (?2 IS NULL OR json_extract(payload_json, '$.accountId')=?2)
             ORDER BY rowid
             LIMIT ?1",
        )?;
        let rows =
            statement.query_map(params![MAX_RECOVERY_OPERATIONS as i64, account_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            })?;
        let mut operations = Vec::new();
        for row in rows {
            let (id, kind, payload_json, attempted_at) = row?;
            let payload: Value = serde_json::from_str(&payload_json)?;
            let operation_account_id = payload
                .get("accountId")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| {
                    StorageError::InvalidData("agenda operation has no account ID".into())
                })?
                .to_owned();
            if account_id.is_none_or(|expected| expected == operation_account_id) {
                operations.push(PendingAgendaOperation {
                    id,
                    kind,
                    account_id: operation_account_id,
                    payload,
                    attempted_at,
                });
            }
        }
        Ok(operations)
    }

    fn commit_agenda_task_upsert(
        &mut self,
        operation_id: &str,
        task: &Task,
    ) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO tasks
             (id, title, description, done, due_at, created_at, source, external_id, account)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(id) DO UPDATE SET title=excluded.title,
               description=excluded.description, done=excluded.done, due_at=excluded.due_at,
               source=excluded.source, external_id=excluded.external_id, account=excluded.account",
            params![
                task.id,
                task.title,
                task.description,
                task.done,
                task.due_at.map(|time| time.timestamp_millis()),
                task.created_at.timestamp_millis(),
                task.source,
                task.external_id,
                task.account,
            ],
        )?;
        finish_agenda_operation_in_transaction(
            &transaction,
            operation_id,
            &[
                "agenda_task_create",
                "agenda_task_update",
                "agenda_task_complete",
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn commit_agenda_task_delete(
        &mut self,
        operation_id: &str,
        task_id: &str,
    ) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        if transaction.execute("DELETE FROM tasks WHERE id=?1", [task_id])? == 0 {
            return Err(StorageError::NotFound);
        }
        finish_agenda_operation_in_transaction(
            &transaction,
            operation_id,
            &["agenda_task_delete"],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn commit_agenda_event_upsert(
        &mut self,
        operation_id: &str,
        event: &CalendarEvent,
    ) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO events
             (id, external_id, calendar_id, calendar_name, title, description,
              start_at, end_at, all_day, read_only)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(id) DO UPDATE SET external_id=excluded.external_id,
              calendar_id=excluded.calendar_id, calendar_name=excluded.calendar_name,
              title=excluded.title, description=excluded.description,
              start_at=excluded.start_at, end_at=excluded.end_at,
              all_day=excluded.all_day, read_only=excluded.read_only",
            params![
                event.id,
                event.external_id,
                event.calendar_id,
                event.calendar_name,
                event.title,
                event.description,
                event.start_at.timestamp_millis(),
                event.end_at.timestamp_millis(),
                event.all_day,
                event.read_only,
            ],
        )?;
        finish_agenda_operation_in_transaction(
            &transaction,
            operation_id,
            &["agenda_event_create", "agenda_event_update"],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn commit_agenda_event_delete(
        &mut self,
        operation_id: &str,
        event_id: &str,
    ) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        if transaction.execute("DELETE FROM events WHERE id=?1", [event_id])? == 0 {
            return Err(StorageError::NotFound);
        }
        finish_agenda_operation_in_transaction(
            &transaction,
            operation_id,
            &["agenda_event_delete"],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn save_draft(
        &mut self,
        draft_id: Option<&str>,
        message: &OutgoingMessage,
    ) -> Result<(DraftSaved, u64), StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        let draft_id = draft_id
            .map(str::to_owned)
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let updated_at = Utc::now();
        transaction.execute(
            "INSERT INTO drafts (id, account_id, message_json, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,
               message_json=excluded.message_json, updated_at=excluded.updated_at",
            params![
                draft_id,
                message.account_id,
                serde_json::to_string(message)?,
                updated_at.timestamp_millis()
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok((
            DraftSaved {
                draft_id,
                updated_at,
            },
            revision,
        ))
    }

    fn list_drafts(&self, account_id: Option<&str>) -> Result<Vec<DraftRecord>, StorageError> {
        let mut statement = self.connection.prepare_cached(
            "SELECT id, message_json, updated_at FROM drafts
             WHERE (?1 IS NULL OR account_id = ?1)
             ORDER BY updated_at DESC, id DESC",
        )?;
        let rows = statement.query_map([account_id], draft_record_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn get_draft(&self, draft_id: &str) -> Result<DraftRecord, StorageError> {
        self.connection
            .query_row(
                "SELECT id, message_json, updated_at FROM drafts WHERE id = ?1",
                [draft_id],
                draft_record_from_row,
            )
            .optional()?
            .ok_or(StorageError::NotFound)
    }

    fn delete_draft(&mut self, draft_id: &str) -> Result<u64, StorageError> {
        let transaction = self.connection.transaction()?;
        if transaction.execute("DELETE FROM drafts WHERE id = ?1", [draft_id])? == 0 {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn list_tasks(&self, include_done: bool) -> Result<Vec<Task>, StorageError> {
        let connection = &self.connection;
        let mut statement = connection.prepare_cached(
            "SELECT id, title, description, done, due_at, created_at, source, external_id, account
             FROM tasks WHERE (?1 = 1 OR done = 0)
             ORDER BY done, due_at IS NULL, due_at, created_at, id",
        )?;
        let rows = statement.query_map([include_done], task_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn get_task(&self, id: &str) -> Result<Task, StorageError> {
        self.connection
            .query_row(
                "SELECT id, title, description, done, due_at, created_at, source, external_id, account
                 FROM tasks WHERE id=?1",
                [id],
                task_from_row,
            )
            .optional()?
            .ok_or(StorageError::NotFound)
    }

    fn upsert_task(&mut self, task: &Task) -> Result<u64, StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT INTO tasks
             (id, title, description, done, due_at, created_at, source, external_id, account)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(id) DO UPDATE SET title=excluded.title,
               description=excluded.description, done=excluded.done, due_at=excluded.due_at,
               source=excluded.source, external_id=excluded.external_id, account=excluded.account",
            params![
                task.id,
                task.title,
                task.description,
                task.done,
                task.due_at.map(|time| time.timestamp_millis()),
                task.created_at.timestamp_millis(),
                task.source,
                task.external_id,
                task.account,
            ],
        )?;
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn complete_task(&mut self, id: &str, done: bool) -> Result<u64, StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        if transaction.execute("UPDATE tasks SET done=?2 WHERE id=?1", params![id, done])? == 0 {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn delete_task(&mut self, id: &str) -> Result<u64, StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        if transaction.execute("DELETE FROM tasks WHERE id=?1", [id])? == 0 {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn upsert_events(&mut self, events: &[CalendarEvent]) -> Result<u64, StorageError> {
        if events.is_empty() {
            return self.revision();
        }
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO events
                 (id, external_id, calendar_id, calendar_name, title, description,
                  start_at, end_at, all_day, read_only)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(id) DO UPDATE SET external_id=excluded.external_id,
                  calendar_id=excluded.calendar_id, calendar_name=excluded.calendar_name,
                  title=excluded.title, description=excluded.description,
                  start_at=excluded.start_at, end_at=excluded.end_at,
                  all_day=excluded.all_day, read_only=excluded.read_only",
            )?;
            for event in events {
                statement.execute(params![
                    event.id,
                    event.external_id,
                    event.calendar_id,
                    event.calendar_name,
                    event.title,
                    event.description,
                    event.start_at.timestamp_millis(),
                    event.end_at.timestamp_millis(),
                    event.all_day,
                    event.read_only,
                ])?;
            }
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn delete_event(&mut self, id: &str) -> Result<u64, StorageError> {
        let connection = &mut self.connection;
        let transaction = connection.transaction()?;
        if transaction.execute("DELETE FROM events WHERE id=?1", [id])? == 0 {
            return Err(StorageError::NotFound);
        }
        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn get_event(&self, id: &str) -> Result<CalendarEvent, StorageError> {
        self.connection
            .query_row(
                "SELECT id, external_id, calendar_id, calendar_name, title, description,
                        start_at, end_at, all_day, read_only
                 FROM events WHERE id=?1",
                [id],
                event_from_row,
            )
            .optional()?
            .ok_or(StorageError::NotFound)
    }

    fn replace_remote_agenda(
        &mut self,
        account_id: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        tasks: &[Task],
        events: &[CalendarEvent],
    ) -> Result<u64, StorageError> {
        if tasks.iter().any(|task| task.account != account_id)
            || events.iter().any(|event| {
                !event
                    .calendar_id
                    .strip_prefix(account_id)
                    .is_some_and(|suffix| suffix.starts_with(':'))
            })
        {
            return Err(StorageError::InvalidData(
                "remote agenda page is not scoped to its account".into(),
            ));
        }

        let transaction = self.connection.transaction()?;
        transaction.execute(
            "DELETE FROM tasks
             WHERE account=?1 AND source IN ('google_tasks', 'microsoft_todo')",
            [account_id],
        )?;
        transaction.execute(
            "DELETE FROM events
             WHERE substr(calendar_id, 1, length(?1) + 1) = ?1 || ':'
               AND start_at < ?3 AND end_at >= ?2",
            params![account_id, start.timestamp_millis(), end.timestamp_millis()],
        )?;

        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO tasks
                 (id, title, description, done, due_at, created_at, source, external_id, account)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(id) DO UPDATE SET title=excluded.title,
                   description=excluded.description, done=excluded.done, due_at=excluded.due_at,
                   source=excluded.source, external_id=excluded.external_id,
                   account=excluded.account",
            )?;
            for task in tasks {
                statement.execute(params![
                    task.id,
                    task.title,
                    task.description,
                    task.done,
                    task.due_at.map(|time| time.timestamp_millis()),
                    task.created_at.timestamp_millis(),
                    task.source,
                    task.external_id,
                    task.account,
                ])?;
            }
        }
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO events
                 (id, external_id, calendar_id, calendar_name, title, description,
                  start_at, end_at, all_day, read_only)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(id) DO UPDATE SET external_id=excluded.external_id,
                  calendar_id=excluded.calendar_id, calendar_name=excluded.calendar_name,
                  title=excluded.title, description=excluded.description,
                  start_at=excluded.start_at, end_at=excluded.end_at,
                  all_day=excluded.all_day, read_only=excluded.read_only",
            )?;
            for event in events {
                statement.execute(params![
                    event.id,
                    event.external_id,
                    event.calendar_id,
                    event.calendar_name,
                    event.title,
                    event.description,
                    event.start_at.timestamp_millis(),
                    event.end_at.timestamp_millis(),
                    event.all_day,
                    event.read_only,
                ])?;
            }
        }

        let revision = bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(revision)
    }

    fn list_events(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<CalendarEvent>, StorageError> {
        let connection = &self.connection;
        let mut statement = connection.prepare_cached(
            "SELECT id, external_id, calendar_id, calendar_name, title, description,
                    start_at, end_at, all_day, read_only
             FROM events WHERE start_at < ?2 AND end_at >= ?1
             ORDER BY start_at, id",
        )?;
        let rows = statement.query_map(
            params![start.timestamp_millis(), end.timestamp_millis()],
            event_from_row,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn dashboard_snapshot(&self) -> Result<DashboardSnapshot, StorageError> {
        let accounts = self.list_accounts()?;
        let recent_mail = self
            .list_messages(&MessageQuery {
                limit: 30,
                ..MessageQuery::default()
            })?
            .messages;
        let tasks = self.list_tasks(true)?;
        let now = Utc::now();
        let events = self.list_events(now - Duration::days(1), now + Duration::days(14))?;
        Ok(DashboardSnapshot {
            revision: self.revision()?,
            accounts,
            recent_mail,
            tasks,
            events,
            sync: SyncStatus {
                running: false,
                last_sync_at: None,
                error: None,
            },
        })
    }

    /// Seeds explicit visual-test fixtures. Callers must opt in; normal startup
    /// never invokes this method.
    fn seed_demo(&mut self) -> Result<(), StorageError> {
        let account = Account {
            id: "demo@example.com".into(),
            address: "demo@example.com".into(),
            display_name: "Alex Morgan".into(),
            provider: "Demo".into(),
            protocol: "LOCAL".into(),
            host: "example.com".into(),
            unread: 3,
            total: 5,
            enabled: true,
        };
        self.upsert_account(&account)?;
        self.upsert_mailboxes(&[
            Mailbox {
                id: "demo-inbox".into(),
                account_id: account.id.clone(),
                name: "Inbox".into(),
                role: Some(MailboxRole::Inbox),
                unread: 3,
                total: 5,
            },
            Mailbox {
                id: "demo-drafts".into(),
                account_id: account.id.clone(),
                name: "Drafts".into(),
                role: Some(MailboxRole::Drafts),
                unread: 0,
                total: 1,
            },
            Mailbox {
                id: "demo-sent".into(),
                account_id: account.id.clone(),
                name: "Sent".into(),
                role: Some(MailboxRole::Sent),
                unread: 0,
                total: 18,
            },
            Mailbox {
                id: "demo-archive".into(),
                account_id: account.id.clone(),
                name: "Archive".into(),
                role: Some(MailboxRole::Archive),
                unread: 0,
                total: 122,
            },
        ])?;
        let now = Utc::now();
        let senders = [
            (
                "Maya Chen",
                "maya@example.com",
                "Design review notes",
                "I added the revised navigation and interaction notes.",
            ),
            (
                "Calendar",
                "calendar@example.com",
                "Tomorrow: project sync",
                "Project sync begins tomorrow at 09:30.",
            ),
            (
                "Jordan Lee",
                "jordan@example.com",
                "Re: Weekend plans",
                "That works perfectly. I will book the table.",
            ),
            (
                "Build System",
                "ci@example.com",
                "QuickMail build succeeded",
                "All checks passed on the main branch.",
            ),
            (
                "Newsletter",
                "hello@example.com",
                "A quieter, faster inbox",
                "Five practical ideas for reducing inbox noise.",
            ),
        ];
        let messages = senders
            .iter()
            .enumerate()
            .map(|(index, (name, address, subject, body))| Message {
                summary: MessageSummary {
                    id: format!("demo@example.com:message-{index}"),
                    account_id: account.id.clone(),
                    mailbox_id: Some("demo-inbox".into()),
                    thread_id: Some(format!("demo-thread-{index}")),
                    subject: (*subject).into(),
                    author: Some(Address {
                        name: (*name).into(),
                        address: (*address).into(),
                    }),
                    timestamp: now - Duration::minutes((index * 47) as i64),
                    read: index >= 3,
                    starred: index == 0,
                    snippet: (*body).into(),
                    has_attachments: index == 0,
                    labels: vec!["Inbox".into()],
                    provider_data: serde_json::json!({"demo": true}),
                },
                to: vec![Address {
                    name: account.display_name.clone(),
                    address: account.address.clone(),
                }],
                cc: vec![],
                bcc: vec![],
                body_text: Some((*body).into()),
                body_html: None,
                attachments: vec![],
            })
            .collect::<Vec<_>>();
        self.upsert_messages(&messages)?;
        self.upsert_task(&Task {
            id: "demo-task-reply".into(),
            title: "Reply to Maya".into(),
            description: "Review the navigation notes".into(),
            done: false,
            due_at: Some(now + Duration::hours(3)),
            created_at: now,
            source: "mail".into(),
            external_id: "mail:demo@example.com:message-0".into(),
            account: account.address.clone(),
        })?;
        self.upsert_task(&Task {
            id: "demo-task-groceries".into(),
            title: "Pick up groceries".into(),
            description: "Milk, coffee, and fruit".into(),
            done: false,
            due_at: Some(now + Duration::days(1)),
            created_at: now,
            source: "local".into(),
            external_id: String::new(),
            account: String::new(),
        })?;
        self.upsert_events(&[CalendarEvent {
            id: "demo-event-sync".into(),
            external_id: "demo-event-sync".into(),
            calendar_id: "demo-calendar".into(),
            calendar_name: "Work".into(),
            title: "Project sync".into(),
            description: "Weekly planning call".into(),
            start_at: now + Duration::days(1),
            end_at: now + Duration::days(1) + Duration::minutes(45),
            all_day: false,
            read_only: false,
        }])?;
        Ok(())
    }
}

fn migrate(connection: &Connection) -> Result<(), StorageError> {
    let mut version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version > SCHEMA_VERSION {
        return Err(StorageError::InvalidData(format!(
            "database schema {version} is newer than supported schema {SCHEMA_VERSION}"
        )));
    }
    if version == 0 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO metadata (key, value) VALUES ('revision', '0');
                 CREATE TABLE accounts (
               id TEXT PRIMARY KEY, address TEXT NOT NULL, display_name TEXT NOT NULL DEFAULT '',
               provider TEXT NOT NULL, protocol TEXT NOT NULL, host TEXT NOT NULL DEFAULT '',
               unread INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
               enabled INTEGER NOT NULL DEFAULT 1, config_json TEXT NOT NULL DEFAULT '{}',
               auth_state TEXT NOT NULL DEFAULT 'ready', auth_error TEXT,
               updated_at INTEGER NOT NULL
             );
             CREATE TABLE messages (
               id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               mailbox_id TEXT, thread_id TEXT, subject TEXT NOT NULL,
               author_name TEXT, author_address TEXT, timestamp_ms INTEGER NOT NULL,
               is_read INTEGER NOT NULL DEFAULT 0, starred INTEGER NOT NULL DEFAULT 0,
               snippet TEXT NOT NULL DEFAULT '', has_attachments INTEGER NOT NULL DEFAULT 0,
               labels_json TEXT NOT NULL DEFAULT '[]', provider_data_json TEXT NOT NULL DEFAULT '{}',
               to_json TEXT NOT NULL DEFAULT '[]', cc_json TEXT NOT NULL DEFAULT '[]',
               bcc_json TEXT NOT NULL DEFAULT '[]', body_text TEXT, body_html TEXT,
               attachments_json TEXT NOT NULL DEFAULT '[]',
               body_loaded INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL
             );
             CREATE TABLE mailboxes (
               id TEXT NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               name TEXT NOT NULL, role TEXT, unread INTEGER NOT NULL DEFAULT 0,
               total INTEGER NOT NULL DEFAULT 0,
               PRIMARY KEY(account_id, id)
             );
             CREATE TABLE mailbox_sync_state (
               account_id TEXT NOT NULL, mailbox_id TEXT NOT NULL, cursor TEXT NOT NULL,
               updated_at INTEGER NOT NULL,
               PRIMARY KEY(account_id, mailbox_id),
               FOREIGN KEY(account_id, mailbox_id)
                 REFERENCES mailboxes(account_id, id) ON DELETE CASCADE
             );
             CREATE INDEX idx_mailboxes_account_role ON mailboxes(account_id, role, name);
             CREATE INDEX idx_messages_mailbox_page
               ON messages(mailbox_id, timestamp_ms DESC, id DESC);
             CREATE INDEX idx_messages_account_page
               ON messages(account_id, timestamp_ms DESC, id DESC);
             CREATE INDEX idx_messages_account_mailbox_page
               ON messages(account_id, mailbox_id, timestamp_ms DESC, id DESC);
             CREATE INDEX idx_messages_account_thread
               ON messages(account_id, thread_id, timestamp_ms, id)
               WHERE thread_id IS NOT NULL;
             CREATE INDEX idx_messages_unread_page
               ON messages(is_read, timestamp_ms DESC, id DESC);
             CREATE VIRTUAL TABLE messages_fts USING fts5(
               message_id UNINDEXED, subject, author, snippet, body_text,
               tokenize='unicode61 remove_diacritics 2'
             );
             CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
               INSERT INTO messages_fts(message_id, subject, author, snippet, body_text)
               VALUES (new.id, new.subject, coalesce(new.author_name, '') || ' ' ||
                       coalesce(new.author_address, ''), new.snippet, coalesce(new.body_text, ''));
             END;
             CREATE TRIGGER messages_fts_update AFTER UPDATE ON messages BEGIN
               DELETE FROM messages_fts WHERE message_id=old.id;
               INSERT INTO messages_fts(message_id, subject, author, snippet, body_text)
               VALUES (new.id, new.subject, coalesce(new.author_name, '') || ' ' ||
                       coalesce(new.author_address, ''), new.snippet, coalesce(new.body_text, ''));
             END;
             CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
               DELETE FROM messages_fts WHERE message_id=old.id;
             END;
             CREATE TABLE tasks (
               id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
               done INTEGER NOT NULL DEFAULT 0, due_at INTEGER, created_at INTEGER NOT NULL,
               source TEXT NOT NULL DEFAULT 'local', external_id TEXT NOT NULL DEFAULT '',
               account TEXT NOT NULL DEFAULT ''
             );
             CREATE UNIQUE INDEX idx_tasks_external_id
               ON tasks(account, source, external_id) WHERE external_id <> '';
             CREATE INDEX idx_tasks_open_due ON tasks(done, due_at, id);
             CREATE TABLE events (
               id TEXT PRIMARY KEY, external_id TEXT NOT NULL DEFAULT '',
               calendar_id TEXT NOT NULL DEFAULT '', calendar_name TEXT NOT NULL DEFAULT '',
               title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
               start_at INTEGER NOT NULL, end_at INTEGER NOT NULL,
               all_day INTEGER NOT NULL DEFAULT 0, read_only INTEGER NOT NULL DEFAULT 0
             );
             CREATE UNIQUE INDEX idx_events_external
               ON events(calendar_id, external_id) WHERE external_id <> '';
             CREATE INDEX idx_events_range ON events(start_at, end_at, id);
             CREATE TABLE operations (
               id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
               state TEXT NOT NULL, created_at INTEGER NOT NULL, attempted_at INTEGER,
               last_error TEXT
             );
             CREATE INDEX idx_operations_pending ON operations(state, created_at, id);
             CREATE TABLE drafts (
               id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
               message_json TEXT NOT NULL, updated_at INTEGER NOT NULL
             );
             CREATE INDEX idx_drafts_account_updated ON drafts(account_id, updated_at DESC, id);
             PRAGMA user_version=8;
             COMMIT;",
        )?;
        version = 8;
    }
    if version == 1 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             ALTER TABLE accounts ADD COLUMN auth_state TEXT NOT NULL DEFAULT 'ready';
             ALTER TABLE accounts ADD COLUMN auth_error TEXT;
             PRAGMA user_version=2;
             COMMIT;",
        )?;
        version = 2;
    }
    if version == 2 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             ALTER TABLE messages ADD COLUMN body_loaded INTEGER NOT NULL DEFAULT 0;
             UPDATE messages SET body_loaded=1
              WHERE body_text IS NOT NULL OR body_html IS NOT NULL
                 OR to_json <> '[]' OR cc_json <> '[]' OR bcc_json <> '[]'
                 OR attachments_json <> '[]';
             PRAGMA user_version=3;
             COMMIT;",
        )?;
        version = 3;
    }
    if version == 3 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             CREATE TABLE mailbox_sync_state (
               account_id TEXT NOT NULL, mailbox_id TEXT NOT NULL, cursor TEXT NOT NULL,
               updated_at INTEGER NOT NULL,
               PRIMARY KEY(account_id, mailbox_id),
               FOREIGN KEY(account_id, mailbox_id)
                 REFERENCES mailboxes(account_id, id) ON DELETE CASCADE
             );
             PRAGMA user_version=4;
             COMMIT;",
        )?;
        version = 4;
    }
    if version == 4 {
        if table_has_column(connection, "messages", "account_id")?
            && table_has_column(connection, "messages", "thread_id")?
            && table_has_column(connection, "messages", "timestamp_ms")?
        {
            connection.execute_batch(
                "BEGIN IMMEDIATE;
                 CREATE INDEX IF NOT EXISTS idx_messages_account_thread
                   ON messages(account_id, thread_id, timestamp_ms, id)
                   WHERE thread_id IS NOT NULL;
                 PRAGMA user_version=5;
                 COMMIT;",
            )?;
        } else {
            // Early development schema fixtures did not yet include the mail
            // metadata columns. They remain readable for account recovery,
            // but cannot benefit from the optional thread index.
            connection.pragma_update(None, "user_version", 5)?;
        }
        version = 5;
    }
    if version == 5 {
        // HTML is sanitized before it enters the cache. When that allowlist
        // changes, an already-sanitized body cannot recover presentation data
        // that an older version discarded. Mark HTML bodies stale so the next
        // mail.get prefers a complete provider refetch under the current
        // sanitizer policy. Keep the old payload as an offline fallback: it is
        // sanitized again before being returned. Plain-text-only bodies remain
        // valid and do not create unnecessary network work.
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             UPDATE messages
                SET body_loaded=0
              WHERE body_html IS NOT NULL;
             PRAGMA user_version=6;
             COMMIT;",
        )?;
        version = 6;
    }
    if version == 6 {
        // Provider-native task identifiers are only stable inside one account
        // and task service. Scope the uniqueness rule accordingly so two
        // Google or Microsoft accounts can cache the same opaque remote ID.
        if table_has_column(connection, "tasks", "external_id")?
            && table_has_column(connection, "tasks", "account")?
            && table_has_column(connection, "tasks", "source")?
        {
            connection.execute_batch(
                "BEGIN IMMEDIATE;
                 DROP INDEX IF EXISTS idx_tasks_external_id;
                 CREATE UNIQUE INDEX idx_tasks_external_id
                   ON tasks(account, source, external_id) WHERE external_id <> '';
                 PRAGMA user_version=7;
                 COMMIT;",
            )?;
        } else {
            connection.pragma_update(None, "user_version", 7)?;
        }
        version = 7;
    }
    if version == 7 {
        // The colour sanitizer now retains safe solid background shorthand
        // and stylesheet comments. Older sanitized HTML has already lost that
        // presentation information, so refetch it lazily while preserving the
        // existing payload as an offline fallback.
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             UPDATE messages
                SET body_loaded=0
              WHERE body_html IS NOT NULL;
             PRAGMA user_version=8;
             COMMIT;",
        )?;
    }
    Ok(())
}

fn table_has_column(
    connection: &Connection,
    table: &str,
    column: &str,
) -> Result<bool, StorageError> {
    let mut statement =
        connection.prepare("SELECT name FROM pragma_table_info(?1) WHERE name=?2")?;
    Ok(statement
        .query_row(params![table, column], |_| Ok(()))
        .optional()?
        .is_some())
}

fn message_summary_from_row(row: &Row<'_>) -> rusqlite::Result<MessageSummary> {
    let timestamp: i64 = row.get(7)?;
    let author_address: Option<String> = row.get(6)?;
    Ok(MessageSummary {
        id: row.get(0)?,
        account_id: row.get(1)?,
        mailbox_id: row.get(2)?,
        thread_id: row.get(3)?,
        subject: row.get(4)?,
        author: author_address.map(|address| Address {
            name: row
                .get::<_, Option<String>>(5)
                .ok()
                .flatten()
                .unwrap_or_default(),
            address,
        }),
        timestamp: timestamp_from_millis(timestamp)?,
        read: row.get(8)?,
        starred: row.get(9)?,
        snippet: row.get(10)?,
        has_attachments: row.get(11)?,
        labels: json_column(row, 12)?,
        provider_data: json_column(row, 13)?,
    })
}

fn cached_message_from_row(row: &Row<'_>) -> rusqlite::Result<(Message, bool)> {
    let summary = message_summary_from_row(row)?;
    let message = Message {
        summary,
        to: json_column(row, 14)?,
        cc: json_column(row, 15)?,
        bcc: json_column(row, 16)?,
        body_text: row.get(17)?,
        body_html: row.get(18)?,
        attachments: json_column(row, 19)?,
    };
    Ok((message, row.get(20)?))
}

fn account_config_from_row(row: &Row<'_>) -> rusqlite::Result<(Account, Value)> {
    let account = Account {
        id: row.get(0)?,
        address: row.get(1)?,
        display_name: row.get(2)?,
        provider: row.get(3)?,
        protocol: row.get(4)?,
        host: row.get(5)?,
        unread: row.get(6)?,
        total: row.get(7)?,
        enabled: row.get(8)?,
    };
    Ok((account, json_column(row, 9)?))
}

fn secure_database_files(path: &Path) -> Result<(), StorageError> {
    for candidate in [
        path.to_path_buf(),
        path.with_file_name(format!(
            "{}-wal",
            path.file_name().unwrap_or_default().to_string_lossy()
        )),
        path.with_file_name(format!(
            "{}-shm",
            path.file_name().unwrap_or_default().to_string_lossy()
        )),
    ] {
        if let Ok(metadata) = std::fs::symlink_metadata(&candidate) {
            if !metadata.file_type().is_file() || metadata.uid() != current_uid() {
                return Err(StorageError::InvalidData(format!(
                    "refusing database file not owned by current user: {}",
                    candidate.display()
                )));
            }
            std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600))
                .map_err(|error| StorageError::InvalidData(error.to_string()))?;
        }
    }
    Ok(())
}

fn ensure_private_directory(path: &Path) -> Result<(), StorageError> {
    let mut missing = Vec::<PathBuf>::new();
    let mut cursor = path;
    while !cursor.exists() {
        missing.push(cursor.to_owned());
        cursor = cursor.parent().ok_or_else(|| {
            StorageError::InvalidData(format!(
                "could not find an existing parent for {}",
                path.display()
            ))
        })?;
    }
    for directory in missing.iter().rev() {
        std::fs::create_dir(directory)
            .map_err(|error| StorageError::InvalidData(error.to_string()))?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|error| StorageError::InvalidData(error.to_string()))?;
    }
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| StorageError::InvalidData(error.to_string()))?;
    if !metadata.file_type().is_dir()
        || metadata.uid() != current_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(StorageError::InvalidData(format!(
            "refusing non-private database directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn current_uid() -> u32 {
    // SAFETY: geteuid takes no pointers and has no preconditions.
    unsafe { libc::geteuid() }
}

fn task_from_row(row: &Row<'_>) -> rusqlite::Result<Task> {
    let due_at: Option<i64> = row.get(4)?;
    Ok(Task {
        id: row.get(0)?,
        title: row.get(1)?,
        description: row.get(2)?,
        done: row.get(3)?,
        due_at: due_at.map(timestamp_from_millis).transpose()?,
        created_at: timestamp_from_millis(row.get(5)?)?,
        source: row.get(6)?,
        external_id: row.get(7)?,
        account: row.get(8)?,
    })
}

fn event_from_row(row: &Row<'_>) -> rusqlite::Result<CalendarEvent> {
    Ok(CalendarEvent {
        id: row.get(0)?,
        external_id: row.get(1)?,
        calendar_id: row.get(2)?,
        calendar_name: row.get(3)?,
        title: row.get(4)?,
        description: row.get(5)?,
        start_at: timestamp_from_millis(row.get(6)?)?,
        end_at: timestamp_from_millis(row.get(7)?)?,
        all_day: row.get(8)?,
        read_only: row.get(9)?,
    })
}

fn timestamp_from_millis(timestamp: i64) -> rusqlite::Result<DateTime<Utc>> {
    DateTime::from_timestamp_millis(timestamp).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Integer,
            format!("invalid millisecond timestamp {timestamp}").into(),
        )
    })
}

fn json_column<T: serde::de::DeserializeOwned>(row: &Row<'_>, index: usize) -> rusqlite::Result<T> {
    let value: String = row.get(index)?;
    serde_json::from_str(&value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn draft_record_from_row(row: &Row<'_>) -> rusqlite::Result<DraftRecord> {
    Ok(DraftRecord {
        draft_id: row.get(0)?,
        message: json_column(row, 1)?,
        updated_at: timestamp_from_millis(row.get(2)?)?,
    })
}

fn encode_cursor(message: &MessageSummary) -> String {
    serde_json::to_string(&(message.timestamp.timestamp_millis(), &message.id))
        .expect("cursor components always serialize")
}

fn decode_cursor(cursor: &str) -> Result<(i64, String), StorageError> {
    let (timestamp, id): (i64, String) =
        serde_json::from_str(cursor).map_err(|_| StorageError::InvalidCursor)?;
    if id.is_empty() {
        return Err(StorageError::InvalidCursor);
    }
    Ok((timestamp, id))
}

const fn mailbox_role_name(role: MailboxRole) -> &'static str {
    match role {
        MailboxRole::Inbox => "inbox",
        MailboxRole::Drafts => "drafts",
        MailboxRole::Sent => "sent",
        MailboxRole::Archive => "archive",
        MailboxRole::Trash => "trash",
        MailboxRole::Spam => "spam",
        MailboxRole::Other => "other",
    }
}

fn parse_mailbox_role(role: &str) -> MailboxRole {
    match role {
        "inbox" => MailboxRole::Inbox,
        "drafts" => MailboxRole::Drafts,
        "sent" => MailboxRole::Sent,
        "archive" => MailboxRole::Archive,
        "trash" => MailboxRole::Trash,
        "spam" => MailboxRole::Spam,
        _ => MailboxRole::Other,
    }
}

fn apply_action_locally(
    transaction: &Transaction<'_>,
    action: &MailAction,
) -> Result<(), StorageError> {
    let (ids, sql, boolean) = match action {
        MailAction::MarkRead { message_ids, read } => (
            message_ids,
            "UPDATE messages SET is_read=?2 WHERE id=?1",
            Some(*read),
        ),
        MailAction::Star {
            message_ids,
            starred,
        } => (
            message_ids,
            "UPDATE messages SET starred=?2 WHERE id=?1",
            Some(*starred),
        ),
        MailAction::Move {
            message_ids,
            mailbox_id,
        } => {
            let mut statement = transaction
                .prepare_cached("UPDATE messages SET mailbox_id=?2, updated_at=?3 WHERE id=?1")?;
            for id in message_ids {
                statement.execute(params![id, mailbox_id, Utc::now().timestamp_millis()])?;
            }
            return Ok(());
        }
        MailAction::SetLabels {
            message_ids,
            labels,
        } => {
            let labels = serde_json::to_string(labels)?;
            let mut statement = transaction
                .prepare_cached("UPDATE messages SET labels_json=?2, updated_at=?3 WHERE id=?1")?;
            for id in message_ids {
                statement.execute(params![id, labels, Utc::now().timestamp_millis()])?;
            }
            return Ok(());
        }
        MailAction::Archive { message_ids } | MailAction::Trash { message_ids } => {
            let mut statement = transaction.prepare_cached("DELETE FROM messages WHERE id=?1")?;
            for id in message_ids {
                statement.execute([id])?;
            }
            return Ok(());
        }
    };
    if ids.is_empty() {
        return Err(StorageError::InvalidData(
            "mail action has no message ids".into(),
        ));
    }
    let mut statement = transaction.prepare_cached(sql)?;
    for id in ids {
        statement.execute(params![id, boolean])?;
    }
    Ok(())
}

fn validate_mail_action(action: &MailAction) -> Result<(), StorageError> {
    let ids = match action {
        MailAction::MarkRead { message_ids, .. }
        | MailAction::Star { message_ids, .. }
        | MailAction::Archive { message_ids }
        | MailAction::Trash { message_ids }
        | MailAction::Move { message_ids, .. }
        | MailAction::SetLabels { message_ids, .. } => message_ids,
    };
    if ids.is_empty() {
        return Err(StorageError::InvalidData(
            "mail action has no message ids".into(),
        ));
    }
    if let MailAction::Move { mailbox_id, .. } = action
        && mailbox_id.trim().is_empty()
    {
        return Err(StorageError::InvalidData(
            "mail move has no destination mailbox".into(),
        ));
    }
    Ok(())
}

fn remove_account_operations(
    transaction: &Transaction<'_>,
    account_id: &str,
) -> Result<(), StorageError> {
    let operations = {
        let mut statement = transaction.prepare(
            "SELECT id, kind, payload_json FROM operations
             WHERE kind IN (
               'mail_action', 'mail_send',
               'agenda_task_create', 'agenda_task_update', 'agenda_task_complete',
               'agenda_task_delete', 'agenda_event_create', 'agenda_event_update',
               'agenda_event_delete'
             )",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };

    let mut delete = transaction.prepare_cached("DELETE FROM operations WHERE id=?1")?;
    for (operation_id, kind, payload_json) in operations {
        if operation_payload_belongs_to_account(&kind, &payload_json, account_id) {
            delete.execute([operation_id])?;
        }
    }
    Ok(())
}

fn operation_payload_belongs_to_account(kind: &str, payload_json: &str, account_id: &str) -> bool {
    let Ok(payload) = serde_json::from_str::<Value>(payload_json) else {
        return false;
    };
    match kind {
        "mail_send"
        | "agenda_task_create"
        | "agenda_task_update"
        | "agenda_task_complete"
        | "agenda_task_delete"
        | "agenda_event_create"
        | "agenda_event_update"
        | "agenda_event_delete" => ["accountId", "account_id"]
            .into_iter()
            .any(|field| payload.get(field).and_then(Value::as_str) == Some(account_id)),
        "mail_action" => ["messageIds", "message_ids"]
            .into_iter()
            .filter_map(|field| payload.get(field).and_then(Value::as_array))
            .flatten()
            .filter_map(Value::as_str)
            .any(|message_id| quickmail_core::is_normalized_message_id(account_id, message_id)),
        _ => false,
    }
}

fn read_revision(connection: &Connection) -> Result<u64, StorageError> {
    let revision: String = connection.query_row(
        "SELECT value FROM metadata WHERE key='revision'",
        [],
        |row| row.get(0),
    )?;
    revision
        .parse()
        .map_err(|_| StorageError::InvalidData("metadata revision is not an integer".into()))
}

fn finish_agenda_operation_in_transaction(
    transaction: &Transaction<'_>,
    operation_id: &str,
    allowed_kinds: &[&str],
) -> Result<(), StorageError> {
    let operation: Option<(String, String)> = transaction
        .query_row(
            "SELECT kind, state FROM operations WHERE id=?1",
            [operation_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((kind, state)) = operation else {
        return Err(StorageError::NotFound);
    };
    if !allowed_kinds.contains(&kind.as_str()) || state != "pending" {
        return Err(StorageError::InvalidData(
            "agenda operation cannot be committed in its current state".into(),
        ));
    }
    transaction.execute(
        "UPDATE operations
         SET state='succeeded', attempted_at=?2, last_error=NULL WHERE id=?1",
        params![operation_id, Utc::now().timestamp_millis()],
    )?;
    Ok(())
}

fn bump_revision(transaction: &Transaction<'_>) -> Result<u64, StorageError> {
    transaction.execute(
        "UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='revision'",
        [],
    )?;
    read_revision(transaction)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use chrono::TimeZone;
    use serde_json::json;
    use tempfile::tempdir;

    use super::*;

    fn account() -> Account {
        Account {
            id: "account-1".into(),
            address: "me@example.com".into(),
            display_name: "Me".into(),
            provider: "test".into(),
            protocol: "TEST".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        }
    }

    fn message(index: usize) -> Message {
        Message {
            summary: MessageSummary {
                id: format!("account-1:message-{index:05}"),
                account_id: "account-1".into(),
                mailbox_id: Some("inbox".into()),
                thread_id: None,
                subject: format!("Subject {index}"),
                author: Some(Address {
                    name: "Alice".into(),
                    address: "alice@example.com".into(),
                }),
                timestamp: Utc
                    .timestamp_millis_opt(1_700_000_000_000 + index as i64)
                    .unwrap(),
                read: false,
                starred: false,
                snippet: "preview only".into(),
                has_attachments: false,
                labels: vec!["Inbox".into()],
                provider_data: json!({}),
            },
            to: vec![],
            cc: vec![],
            bcc: vec![],
            body_text: Some(format!("large lazy body {index}")),
            body_html: None,
            attachments: vec![],
        }
    }

    fn mailbox(id: &str, role: Option<MailboxRole>) -> Mailbox {
        Mailbox {
            id: id.into(),
            account_id: "account-1".into(),
            name: id.into(),
            role,
            unread: 0,
            total: 0,
        }
    }

    #[tokio::test]
    async fn file_database_uses_wal_and_current_migration() {
        let directory = tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("mail.db");
        let database = Database::open(&path).unwrap();
        assert_eq!(database.journal_mode().await.unwrap(), "wal");
        assert_eq!(database.schema_version().await.unwrap(), SCHEMA_VERSION);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        for suffix in ["-wal", "-shm"] {
            let sidecar = path.with_file_name(format!("mail.db{suffix}"));
            if sidecar.exists() {
                assert_eq!(
                    std::fs::metadata(sidecar).unwrap().permissions().mode() & 0o777,
                    0o600
                );
            }
        }
    }

    #[test]
    fn database_creates_private_leaf_directories_without_chmodding_ancestor() {
        let directory = tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        let app_directory = directory.path().join("quickmail").join("data");
        let _database = Database::open(app_directory.join("mail.db")).unwrap();
        assert_eq!(
            std::fs::metadata(directory.path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        assert_eq!(
            std::fs::metadata(&app_directory)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }

    #[test]
    fn database_rejects_an_existing_shared_data_directory() {
        let directory = tempdir().unwrap();
        let shared = directory.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(
            Database::open(shared.join("mail.db")),
            Err(StorageError::InvalidData(_))
        ));
    }

    #[tokio::test]
    async fn schema_one_database_migrates_account_auth_state() {
        let directory = tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("legacy.db");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE accounts (
                   id TEXT PRIMARY KEY, address TEXT NOT NULL, display_name TEXT NOT NULL DEFAULT '',
                   provider TEXT NOT NULL, protocol TEXT NOT NULL, host TEXT NOT NULL DEFAULT '',
                   unread INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0,
                   enabled INTEGER NOT NULL DEFAULT 1, config_json TEXT NOT NULL DEFAULT '{}',
                   updated_at INTEGER NOT NULL
                 );
                 CREATE TABLE messages (
                   id TEXT PRIMARY KEY, to_json TEXT NOT NULL DEFAULT '[]',
                   cc_json TEXT NOT NULL DEFAULT '[]', bcc_json TEXT NOT NULL DEFAULT '[]',
                   body_text TEXT, body_html TEXT,
                   attachments_json TEXT NOT NULL DEFAULT '[]'
                 );
                 PRAGMA user_version=1;",
            )
            .unwrap();
        drop(connection);

        let database = Database::open(path).unwrap();
        assert_eq!(database.schema_version().await.unwrap(), SCHEMA_VERSION);
        assert_eq!(database.account_auth_state("missing").await.unwrap(), None);
    }

    #[test]
    fn schema_three_migration_adds_scoped_mailbox_sync_state() {
        let mut repository = Repository::open_in_memory().unwrap();
        repository
            .connection
            .execute_batch("DROP TABLE mailbox_sync_state; PRAGMA user_version=3;")
            .unwrap();

        migrate(&repository.connection).unwrap();
        assert_eq!(repository.schema_version().unwrap(), SCHEMA_VERSION);
        repository.upsert_account(&account()).unwrap();
        repository
            .upsert_mailboxes(&[mailbox("inbox", Some(MailboxRole::Inbox))])
            .unwrap();
        repository
            .apply_mailbox_sync_page(
                "account-1",
                "inbox",
                &MailboxSyncPage {
                    messages: Vec::new(),
                    removed_message_ids: Vec::new(),
                    cursor: Some("777:42".into()),
                    reset: false,
                },
            )
            .unwrap();
        assert_eq!(
            repository
                .mailbox_sync_cursor("account-1", "inbox")
                .unwrap()
                .as_deref(),
            Some("777:42")
        );
    }

    #[test]
    fn schema_five_migration_marks_html_stale_without_discarding_cached_payload() {
        let mut repository = Repository::open_in_memory().unwrap();
        repository.upsert_account(&account()).unwrap();

        let mut html = message(41);
        html.summary.has_attachments = true;
        html.to = vec![Address {
            name: "Recipient".into(),
            address: "recipient@example.com".into(),
        }];
        html.body_html =
            Some("<table width=\"700\" align=\"center\"><tr><td>mail</td></tr></table>".into());
        html.attachments = vec![quickmail_core::Attachment {
            id: "attachment-1".into(),
            filename: "agenda.pdf".into(),
            content_type: "application/pdf".into(),
            size: 42,
            inline: false,
            content_id: None,
        }];
        let expected_html = html.clone();
        let plain = message(42);
        repository.upsert_messages(&[html, plain.clone()]).unwrap();
        repository
            .connection
            .pragma_update(None, "user_version", 5)
            .unwrap();

        migrate(&repository.connection).unwrap();

        assert_eq!(repository.schema_version().unwrap(), SCHEMA_VERSION);
        let (invalidated, body_loaded) = repository
            .get_cached_message("account-1:message-00041")
            .unwrap()
            .unwrap();
        assert!(!body_loaded);
        assert_eq!(invalidated.to, expected_html.to);
        assert_eq!(invalidated.cc, expected_html.cc);
        assert_eq!(invalidated.bcc, expected_html.bcc);
        assert_eq!(invalidated.body_text, expected_html.body_text);
        assert_eq!(invalidated.body_html, expected_html.body_html);
        assert_eq!(invalidated.attachments, expected_html.attachments);
        assert!(invalidated.summary.has_attachments);

        let (still_cached, body_loaded) = repository
            .get_cached_message("account-1:message-00042")
            .unwrap()
            .unwrap();
        assert!(body_loaded);
        assert_eq!(still_cached.body_text, plain.body_text);
    }

    #[test]
    fn schema_seven_migration_refreshes_html_for_the_colour_policy() {
        let mut repository = Repository::open_in_memory().unwrap();
        repository.upsert_account(&account()).unwrap();
        let mut html = message(43);
        html.body_html = Some("<div style=\"color:#202124\">cached mail</div>".into());
        repository
            .upsert_messages(std::slice::from_ref(&html))
            .unwrap();
        repository
            .connection
            .pragma_update(None, "user_version", 7)
            .unwrap();

        migrate(&repository.connection).unwrap();

        let (preserved, body_loaded) = repository
            .get_cached_message("account-1:message-00043")
            .unwrap()
            .unwrap();
        assert_eq!(repository.schema_version().unwrap(), SCHEMA_VERSION);
        assert!(!body_loaded);
        assert_eq!(preserved.body_html, html.body_html);
    }

    #[tokio::test]
    async fn task_upsert_creates_and_updates_external_id() {
        let database = Database::open_in_memory().unwrap();
        let created_at = Utc.timestamp_millis_opt(1_700_000_000_000).unwrap();
        let mut task = Task {
            id: "task-1".into(),
            title: "Reply to Maya".into(),
            description: "Review the navigation notes".into(),
            done: false,
            due_at: None,
            created_at,
            source: "mail".into(),
            external_id: "mail:account-1:message-1".into(),
            account: "account-1".into(),
        };

        database.upsert_task(&task).await.unwrap();
        let created = database.list_tasks(true).await.unwrap();
        assert_eq!(created, vec![task.clone()]);

        task.title = "Reply sent".into();
        task.description = "Follow-up complete".into();
        task.done = true;
        task.due_at = Some(Utc.timestamp_millis_opt(1_700_003_600_000).unwrap());
        task.external_id = "mail:account-1:message-2".into();
        database.upsert_task(&task).await.unwrap();

        let updated = database.list_tasks(true).await.unwrap();
        assert_eq!(updated, vec![task]);
    }

    #[tokio::test]
    async fn remote_agenda_replacement_is_account_scoped_and_keeps_local_tasks() {
        let database = Database::open_in_memory().unwrap();
        let start = Utc.timestamp_millis_opt(1_700_000_000_000).unwrap();
        let end = start + Duration::days(30);
        let local = Task {
            id: "local-task".into(),
            title: "Local".into(),
            description: String::new(),
            done: false,
            due_at: Some(start),
            created_at: start,
            source: "local".into(),
            external_id: String::new(),
            account: String::new(),
        };
        database.upsert_task(&local).await.unwrap();

        let remote = Task {
            id: "account-1:task:remote-1".into(),
            title: "Remote".into(),
            description: String::new(),
            done: false,
            due_at: Some(start + Duration::days(1)),
            created_at: start,
            source: "google_tasks".into(),
            external_id: "remote-1".into(),
            account: "account-1".into(),
        };
        let event = CalendarEvent {
            id: "account-1:event:remote-1".into(),
            external_id: "remote-1".into(),
            calendar_id: "account-1:primary".into(),
            calendar_name: "Personal".into(),
            title: "Remote event".into(),
            description: String::new(),
            start_at: start + Duration::days(2),
            end_at: start + Duration::days(2) + Duration::hours(1),
            all_day: false,
            read_only: false,
        };
        database
            .replace_remote_agenda(
                "account-1",
                start,
                end,
                std::slice::from_ref(&remote),
                std::slice::from_ref(&event),
            )
            .await
            .unwrap();
        assert_eq!(database.get_task(&remote.id).await.unwrap(), remote);
        assert_eq!(database.get_event(&event.id).await.unwrap(), event);

        database
            .replace_remote_agenda("account-1", start, end, &[], &[])
            .await
            .unwrap();
        assert_eq!(database.list_tasks(true).await.unwrap(), vec![local]);
        assert!(matches!(
            database.get_event("account-1:event:remote-1").await,
            Err(StorageError::NotFound)
        ));
    }

    #[tokio::test]
    async fn remote_agenda_mutations_are_queued_without_credentials() {
        let database = Database::open_in_memory().unwrap();
        let (operation_id, _) = database
            .queue_agenda_operation(
                "agenda_task_create",
                "account-1",
                &json!({"id": "stable-task", "title": "Plan trip"}),
            )
            .await
            .unwrap();
        let stored: (String, String, String) = database
            .call(move |repository| {
                repository
                    .connection
                    .query_row(
                        "SELECT kind, payload_json, state FROM operations WHERE id=?1",
                        [operation_id],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                    )
                    .map_err(Into::into)
            })
            .await
            .unwrap();
        assert_eq!(stored.0, "agenda_task_create");
        assert_eq!(stored.2, "pending");
        let payload: Value = serde_json::from_str(&stored.1).unwrap();
        assert_eq!(payload["accountId"], "account-1");
        assert_eq!(payload["id"], "stable-task");
        assert!(!stored.1.to_ascii_lowercase().contains("token"));
    }

    #[tokio::test]
    async fn remote_agenda_cache_and_operation_completion_commit_atomically() {
        let database = Database::open_in_memory().unwrap();
        let task = Task {
            id: "account-1:agenda-task-v1.stable".into(),
            title: "Plan trip".into(),
            description: "Book train".into(),
            done: false,
            due_at: None,
            created_at: Utc
                .timestamp_millis_opt(Utc::now().timestamp_millis())
                .single()
                .unwrap(),
            source: "google_tasks".into(),
            external_id: "remote-1".into(),
            account: "account-1".into(),
        };
        let (wrong_operation_id, _) = database
            .queue_agenda_operation(
                "agenda_event_create",
                "account-1",
                &json!({"id": "event-1"}),
            )
            .await
            .unwrap();
        assert!(matches!(
            database
                .commit_agenda_task_upsert(&wrong_operation_id, &task)
                .await,
            Err(StorageError::InvalidData(_))
        ));
        assert!(matches!(
            database.get_task(&task.id).await,
            Err(StorageError::NotFound)
        ));

        let (create_operation_id, _) = database
            .queue_agenda_operation(
                "agenda_task_create",
                "account-1",
                &serde_json::to_value(&task).unwrap(),
            )
            .await
            .unwrap();
        database
            .commit_agenda_task_upsert(&create_operation_id, &task)
            .await
            .unwrap();
        assert_eq!(database.get_task(&task.id).await.unwrap(), task);

        let (delete_operation_id, _) = database
            .queue_agenda_operation(
                "agenda_task_delete",
                "account-1",
                &json!({"taskId": task.id}),
            )
            .await
            .unwrap();
        database
            .commit_agenda_task_delete(&delete_operation_id, &task.id)
            .await
            .unwrap();
        assert!(matches!(
            database.get_task(&task.id).await,
            Err(StorageError::NotFound)
        ));

        let operation_ids = [wrong_operation_id, create_operation_id, delete_operation_id];
        let states: Vec<String> = database
            .call(move |repository| {
                operation_ids
                    .iter()
                    .map(|operation_id| {
                        repository
                            .connection
                            .query_row(
                                "SELECT state FROM operations WHERE id=?1",
                                [operation_id],
                                |row| row.get(0),
                            )
                            .map_err(Into::into)
                    })
                    .collect()
            })
            .await
            .unwrap();
        assert_eq!(states, ["pending", "succeeded", "succeeded"]);
    }

    #[tokio::test]
    async fn pending_agenda_operations_keep_insertion_order_and_account_scope() {
        let database = Database::open_in_memory().unwrap();
        let (first, _) = database
            .queue_agenda_operation("agenda_task_update", "account-1", &json!({"id": "first"}))
            .await
            .unwrap();
        let (second, _) = database
            .queue_agenda_operation(
                "agenda_task_complete",
                "account-1",
                &json!({"taskId": "first", "done": true}),
            )
            .await
            .unwrap();
        let (other, _) = database
            .queue_agenda_operation(
                "agenda_event_delete",
                "account-2",
                &json!({"eventId": "event-2"}),
            )
            .await
            .unwrap();

        database
            .defer_operation(&first, "temporary provider failure")
            .await
            .unwrap();
        let account_operations = database
            .list_pending_agenda_operations(Some("account-1"))
            .await
            .unwrap();
        assert_eq!(
            account_operations
                .iter()
                .map(|operation| operation.id.as_str())
                .collect::<Vec<_>>(),
            [first.as_str(), second.as_str()]
        );
        assert!(account_operations[0].attempted_at.is_some());

        let all_operations = database.list_pending_agenda_operations(None).await.unwrap();
        assert_eq!(
            all_operations
                .iter()
                .map(|operation| operation.id.as_str())
                .collect::<Vec<_>>(),
            [first.as_str(), second.as_str(), other.as_str()]
        );
    }

    #[tokio::test]
    async fn batched_insert_and_keyset_pages_are_complete_and_stable() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        let messages = (0..2_000).map(message).collect::<Vec<_>>();
        database.upsert_messages(&messages).await.unwrap();

        let mut cursor = None;
        let mut ids = Vec::new();
        loop {
            let page = database
                .list_messages(&MessageQuery {
                    mailbox_id: Some("inbox".into()),
                    cursor: cursor.clone(),
                    limit: 73,
                    ..MessageQuery::default()
                })
                .await
                .unwrap();
            assert!(
                page.messages
                    .iter()
                    .all(|message| message.snippet == "preview only")
            );
            ids.extend(page.messages.into_iter().map(|message| message.id));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }

        assert_eq!(ids.len(), 2_000);
        assert_eq!(ids.iter().collect::<HashSet<_>>().len(), 2_000);
        assert_eq!(ids.first().unwrap(), "account-1:message-01999");
        assert_eq!(ids.last().unwrap(), "account-1:message-00000");
        assert_eq!(
            database
                .get_message("account-1:message-00420")
                .await
                .unwrap()
                .unwrap()
                .body_text
                .as_deref(),
            Some("large lazy body 420")
        );
    }

    #[tokio::test]
    async fn thread_lookup_is_account_scoped_chronological_and_bounded() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();

        let mut newest = message(3);
        newest.summary.thread_id = Some("account-1:thread:root@example.com".into());
        newest.summary.provider_data = json!({"messageId": "newest@example.com"});
        let mut oldest = message(1);
        oldest.summary.thread_id = newest.summary.thread_id.clone();
        oldest.summary.provider_data = json!({"messageId": "oldest@example.com"});
        let mut duplicate = newest.clone();
        duplicate.summary.id = "account-1:all-mail-copy".into();
        duplicate.summary.mailbox_id = Some("all-mail".into());
        let unrelated = message(2);
        database
            .upsert_messages(&[newest.clone(), duplicate, unrelated, oldest.clone()])
            .await
            .unwrap();

        let thread = database.get_thread(&newest.summary.id).await.unwrap();
        assert_eq!(thread.id, "account-1:thread:root@example.com");
        assert_eq!(
            thread
                .messages
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            [oldest.summary.id.as_str(), newest.summary.id.as_str()]
        );
        assert!(!thread.truncated);

        let singleton = database
            .get_thread("account-1:message-00002")
            .await
            .unwrap();
        assert_eq!(singleton.messages.len(), 1);
        assert_eq!(singleton.id, "account-1:message-00002");
        assert!(matches!(
            database.get_thread("account-1:missing").await,
            Err(StorageError::NotFound)
        ));
    }

    #[tokio::test]
    async fn bounded_thread_always_retains_an_old_anchor() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        let messages = (0..105)
            .map(|index| {
                let mut item = message(index);
                item.summary.thread_id = Some("account-1:thread:long".into());
                item.summary.provider_data =
                    json!({"messageId": format!("message-{index}@example.com")});
                item
            })
            .collect::<Vec<_>>();
        let anchor_id = messages[0].summary.id.clone();
        database.upsert_messages(&messages).await.unwrap();

        let thread = database.get_thread(&anchor_id).await.unwrap();
        assert!(thread.truncated);
        assert_eq!(thread.messages.len(), MAX_THREAD_MESSAGES);
        assert!(
            thread
                .messages
                .iter()
                .any(|message| message.id == anchor_id)
        );
        assert_eq!(thread.messages.first().unwrap().id, anchor_id);
        assert_eq!(
            thread.messages.last().unwrap().id,
            messages.last().unwrap().summary.id
        );
    }

    #[tokio::test]
    async fn thread_metadata_backfill_advances_after_reconciliation() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        let messages = (0..70).map(message).collect::<Vec<_>>();
        database.upsert_messages(&messages).await.unwrap();

        let first = database
            .thread_metadata_backfill_ids("account-1", "inbox", 8)
            .await
            .unwrap();
        assert_eq!(first.len(), 8);
        assert!(first.contains(&messages[0].summary.id));
        let mut reconciled = first
            .iter()
            .enumerate()
            .map(|(index, id)| {
                let mut summary = messages[index].summary.clone();
                summary.id = id.clone();
                summary.thread_id = Some(format!("account-1:thread:{index}"));
                summary
            })
            .collect::<Vec<_>>();
        // Retain deterministic IDs even if row ordering changes in the
        // future; only the newly populated thread field matters here.
        reconciled.sort_by(|left, right| left.id.cmp(&right.id));
        database
            .upsert_message_summaries(&reconciled)
            .await
            .unwrap();

        let second = database
            .thread_metadata_backfill_ids("account-1", "inbox", 8)
            .await
            .unwrap();
        assert_eq!(second.len(), 8);
        assert!(second.iter().all(|id| !first.contains(id)));
    }

    #[tokio::test]
    async fn mailbox_sync_cursor_is_atomic_scoped_and_resets_uid_generation() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        database
            .upsert_mailboxes(&[
                mailbox("inbox", Some(MailboxRole::Inbox)),
                mailbox("archive", Some(MailboxRole::Archive)),
            ])
            .await
            .unwrap();

        let existing = message(1);
        let mut archived = message(2);
        archived.summary.id = "account-1:archive-message-00002".into();
        archived.summary.mailbox_id = Some("archive".into());
        database
            .upsert_messages(&[existing.clone(), archived.clone()])
            .await
            .unwrap();

        let mut reconciled = existing.summary.clone();
        reconciled.subject = "Updated envelope".into();
        reconciled.read = true;
        reconciled.starred = true;
        database
            .apply_mailbox_sync_page(
                "account-1",
                "inbox",
                &MailboxSyncPage {
                    messages: vec![reconciled],
                    removed_message_ids: Vec::new(),
                    cursor: Some("7:42".into()),
                    reset: false,
                },
            )
            .await
            .unwrap();

        assert_eq!(
            database
                .mailbox_sync_cursor("account-1", "inbox")
                .await
                .unwrap()
                .as_deref(),
            Some("7:42")
        );
        assert_eq!(
            database
                .mailbox_sync_cursor("account-1", "archive")
                .await
                .unwrap(),
            None
        );
        let reconciled = database
            .get_message(&existing.summary.id)
            .await
            .unwrap()
            .unwrap();
        assert!(reconciled.summary.read && reconciled.summary.starred);
        assert_eq!(reconciled.summary.subject, "Updated envelope");
        assert_eq!(reconciled.body_text, existing.body_text);

        let mut invalid = message(99).summary;
        invalid.mailbox_id = Some("archive".into());
        assert!(matches!(
            database
                .apply_mailbox_sync_page(
                    "account-1",
                    "inbox",
                    &MailboxSyncPage {
                        messages: vec![invalid],
                        removed_message_ids: Vec::new(),
                        cursor: Some("7:99".into()),
                        reset: false,
                    },
                )
                .await,
            Err(StorageError::InvalidData(_))
        ));
        assert_eq!(
            database
                .mailbox_sync_cursor("account-1", "inbox")
                .await
                .unwrap()
                .as_deref(),
            Some("7:42")
        );

        database
            .apply_mailbox_sync_page(
                "account-1",
                "inbox",
                &MailboxSyncPage {
                    messages: Vec::new(),
                    removed_message_ids: vec![existing.summary.id.clone()],
                    cursor: Some("7:43".into()),
                    reset: false,
                },
            )
            .await
            .unwrap();
        assert!(
            database
                .get_message(&existing.summary.id)
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            database
                .get_message(&archived.summary.id)
                .await
                .unwrap()
                .is_some()
        );
        assert_eq!(
            database
                .mailbox_sync_cursor("account-1", "inbox")
                .await
                .unwrap()
                .as_deref(),
            Some("7:43")
        );

        assert!(matches!(
            database
                .apply_mailbox_sync_page(
                    "account-1",
                    "inbox",
                    &MailboxSyncPage {
                        messages: Vec::new(),
                        removed_message_ids: vec![archived.summary.id.clone()],
                        cursor: Some("7:44".into()),
                        reset: false,
                    },
                )
                .await,
            Err(StorageError::InvalidData(_))
        ));
        assert!(
            database
                .get_message(&archived.summary.id)
                .await
                .unwrap()
                .is_some()
        );
        assert_eq!(
            database
                .mailbox_sync_cursor("account-1", "inbox")
                .await
                .unwrap()
                .as_deref(),
            Some("7:43")
        );

        let mut replacement = message(3).summary;
        replacement.id = "account-1:new-generation-message-00003".into();
        database
            .apply_mailbox_sync_page(
                "account-1",
                "inbox",
                &MailboxSyncPage {
                    messages: vec![replacement.clone()],
                    removed_message_ids: Vec::new(),
                    cursor: Some("8:3".into()),
                    reset: true,
                },
            )
            .await
            .unwrap();

        assert!(
            database
                .get_message(&existing.summary.id)
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            database
                .get_message(&replacement.id)
                .await
                .unwrap()
                .is_some()
        );
        assert!(
            database
                .get_message(&archived.summary.id)
                .await
                .unwrap()
                .is_some()
        );
        assert_eq!(
            database
                .mailbox_sync_cursor("account-1", "inbox")
                .await
                .unwrap()
                .as_deref(),
            Some("8:3")
        );
    }

    #[tokio::test]
    async fn mail_actions_apply_to_cache_only_after_provider_confirmation() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        database.upsert_messages(&[message(1)]).await.unwrap();
        let before = database.revision().await.unwrap();
        let (operation_id, queued) = database
            .apply_mail_action(&MailAction::MarkRead {
                message_ids: vec!["account-1:message-00001".into()],
                read: true,
            })
            .await
            .unwrap();
        assert_eq!(queued, before + 1);
        assert!(
            !database
                .get_message("account-1:message-00001")
                .await
                .unwrap()
                .unwrap()
                .summary
                .read
        );
        let action = MailAction::MarkRead {
            message_ids: vec!["account-1:message-00001".into()],
            read: true,
        };
        let completed = database
            .finish_mail_action(&operation_id, &action, Ok(()))
            .await
            .unwrap();
        assert_eq!(completed, queued + 1);
        assert!(
            database
                .get_message("account-1:message-00001")
                .await
                .unwrap()
                .unwrap()
                .summary
                .read
        );
    }

    #[tokio::test]
    async fn confirmed_archive_and_trash_remove_cache_but_failures_do_not() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        let archived = message(1);
        let failed_trash = message(2);
        database
            .upsert_messages(&[archived.clone(), failed_trash.clone()])
            .await
            .unwrap();

        let archive_action = MailAction::Archive {
            message_ids: vec![archived.summary.id.clone()],
        };
        let (archive_operation, queued_revision) =
            database.apply_mail_action(&archive_action).await.unwrap();
        assert!(
            database
                .get_message(&archived.summary.id)
                .await
                .unwrap()
                .is_some()
        );
        let completed_revision = database
            .finish_mail_action(&archive_operation, &archive_action, Ok(()))
            .await
            .unwrap();
        assert!(completed_revision > queued_revision);
        assert!(
            database
                .get_message(&archived.summary.id)
                .await
                .unwrap()
                .is_none()
        );

        let trash_action = MailAction::Trash {
            message_ids: vec![failed_trash.summary.id.clone()],
        };
        let (trash_operation, _) = database.apply_mail_action(&trash_action).await.unwrap();
        database
            .finish_mail_action(
                &trash_operation,
                &trash_action,
                Err("provider rejected move".into()),
            )
            .await
            .unwrap();
        assert!(
            database
                .get_message(&failed_trash.summary.id)
                .await
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn account_removal_deletes_scoped_operations_without_retaining_message_content() {
        let mut repository = Repository::open_in_memory().unwrap();
        let first_account = account();
        let second_account = Account {
            id: "account-2".into(),
            address: "other@example.com".into(),
            ..account()
        };
        repository.upsert_account(&first_account).unwrap();
        repository.upsert_account(&second_account).unwrap();

        let first_message = message(1);
        let mut second_message = message(2);
        second_message.summary.id = "account-2:message-00002".into();
        second_message.summary.account_id = second_account.id.clone();
        repository
            .upsert_messages(&[first_message, second_message])
            .unwrap();

        let private_recipient = "private-recipient@example.invalid";
        let private_subject = "private-subject-marker";
        let private_body = "private-body-marker";
        let first_outgoing = OutgoingMessage {
            draft_id: None,
            account_id: first_account.id.clone(),
            to: vec![Address {
                name: "Private recipient".into(),
                address: private_recipient.into(),
            }],
            cc: vec![],
            bcc: vec![],
            subject: private_subject.into(),
            body_text: Some(private_body.into()),
            body_html: None,
            in_reply_to: None,
        };
        let (first_send, _) = repository.queue_outgoing(&first_outgoing).unwrap();
        let first_send_payload: String = repository
            .connection
            .query_row(
                "SELECT payload_json FROM operations WHERE id=?1",
                [first_send],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&first_send_payload).unwrap(),
            json!({"accountId": "account-1"})
        );
        for private_value in [private_recipient, private_subject, private_body] {
            assert!(!first_send_payload.contains(private_value));
        }

        let second_outgoing = OutgoingMessage {
            account_id: second_account.id.clone(),
            subject: "second account remains".into(),
            ..first_outgoing.clone()
        };
        repository.queue_outgoing(&second_outgoing).unwrap();
        repository
            .apply_mail_action(&MailAction::MarkRead {
                message_ids: vec!["account-1:message-00001".into()],
                read: true,
            })
            .unwrap();
        let second_account_action = MailAction::Star {
            message_ids: vec!["account-2:message-00002".into()],
            starred: true,
        };
        let (second_account_operation, _) = repository
            .apply_mail_action(&second_account_action)
            .unwrap();
        repository
            .finish_mail_action(&second_account_operation, &second_account_action, Ok(()))
            .unwrap();

        // Existing databases may still contain the former full outgoing
        // payload. Account removal must scrub those rows too.
        repository
            .connection
            .execute(
                "INSERT INTO operations (id, kind, payload_json, state, created_at)
                 VALUES ('legacy-account-1-send', 'mail_send', ?1, 'succeeded', 0)",
                [serde_json::to_string(&first_outgoing).unwrap()],
            )
            .unwrap();
        repository
            .connection
            .execute(
                "INSERT INTO operations (id, kind, payload_json, state, created_at)
                 VALUES ('legacy-account-1-action', 'mail_action', ?1, 'succeeded', 0)",
                [json!({
                    "kind": "trash",
                    "message_ids": ["account-1:message-00001"]
                })
                .to_string()],
            )
            .unwrap();

        repository.remove_account(&first_account.id).unwrap();

        let remaining = {
            let mut statement = repository
                .connection
                .prepare("SELECT kind, payload_json FROM operations ORDER BY id")
                .unwrap();
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        assert!(remaining.iter().all(|(kind, payload)| {
            !operation_payload_belongs_to_account(kind, payload, &first_account.id)
        }));
        for private_value in [private_recipient, private_subject, private_body] {
            assert!(
                remaining
                    .iter()
                    .all(|(_, payload)| !payload.contains(private_value))
            );
        }
        assert!(remaining.iter().any(|(kind, payload)| {
            operation_payload_belongs_to_account(kind, payload, &second_account.id)
        }));
        assert_eq!(repository.list_accounts().unwrap(), vec![second_account]);
        assert!(
            repository
                .get_cached_message("account-2:message-00002")
                .unwrap()
                .unwrap()
                .0
                .summary
                .starred
        );
    }

    #[tokio::test]
    async fn full_empty_message_is_distinct_from_an_unloaded_summary() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        let mut full = message(12);
        full.body_text = None;
        full.body_html = None;
        let summary = full.summary.clone();

        database.upsert_message_summaries(&[summary]).await.unwrap();
        let (_, loaded) = database
            .get_cached_message("account-1:message-00012")
            .await
            .unwrap()
            .unwrap();
        assert!(!loaded);

        database.upsert_messages(&[full]).await.unwrap();
        let (cached, loaded) = database
            .get_cached_message("account-1:message-00012")
            .await
            .unwrap()
            .unwrap();
        assert!(loaded);
        assert!(cached.body_text.is_none());
        assert!(cached.body_html.is_none());

        database
            .upsert_message_summaries(std::slice::from_ref(&cached.summary))
            .await
            .unwrap();
        assert!(
            database
                .get_cached_message("account-1:message-00012")
                .await
                .unwrap()
                .unwrap()
                .1
        );
    }

    #[tokio::test]
    async fn account_filter_prevents_native_id_and_mailbox_collisions() {
        let database = Database::open_in_memory().unwrap();
        let first_account = account();
        let second_account = Account {
            id: "account-2".into(),
            address: "other@example.com".into(),
            ..account()
        };
        database.upsert_account(&first_account).await.unwrap();
        database.upsert_account(&second_account).await.unwrap();
        let first = message(7);
        let mut second = message(7);
        second.summary.id = quickmail_core::normalized_message_id("account-2", "message-00007");
        second.summary.account_id = "account-2".into();
        second.summary.subject = "Second account".into();
        database.upsert_messages(&[first, second]).await.unwrap();

        let page = database
            .list_messages(&MessageQuery {
                account_id: Some("account-2".into()),
                mailbox_id: Some("inbox".into()),
                limit: 50,
                ..MessageQuery::default()
            })
            .await
            .unwrap();
        assert_eq!(page.messages.len(), 1);
        assert_eq!(page.messages[0].id, "account-2:message-00007");
        assert_eq!(page.messages[0].subject, "Second account");
    }

    #[tokio::test]
    async fn account_auth_failures_are_persisted() {
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account()).await.unwrap();
        database
            .set_account_auth_state("account-1", "needs_auth", Some("authorization expired"))
            .await
            .unwrap();
        assert_eq!(
            database.account_auth_state("account-1").await.unwrap(),
            Some(("needs_auth".into(), Some("authorization expired".into())))
        );
    }

    #[tokio::test]
    async fn account_count_refresh_preserves_provider_configuration() {
        let database = Database::open_in_memory().unwrap();
        let config = json!({
            "provider": "imap",
            "imap": {"host": "imap.example.com", "port": 993}
        });
        database
            .upsert_account_config(&account(), config.clone())
            .await
            .unwrap();

        database
            .update_account_counts("account-1", 9, 240)
            .await
            .unwrap();

        let (updated, stored_config) = database.account_config("account-1").await.unwrap().unwrap();
        assert_eq!((updated.unread, updated.total), (9, 240));
        assert_eq!(stored_config, config);
    }
}
