use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use mail_builder::MessageBuilder;
use mail_parser::{MessageParser, MimeHeaders};
use quickmail_core::{Address, OutgoingMessage};
use thiserror::Error;
use uuid::Uuid;

use super::{MAX_MAIL_ATTACHMENT_BYTES, MAX_MAIL_MESSAGE_BYTES, MAX_MIME_ATTACHMENTS};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ParsedMime {
    pub(crate) subject: String,
    pub(crate) from: Option<Address>,
    pub(crate) to: Vec<Address>,
    pub(crate) cc: Vec<Address>,
    pub(crate) bcc: Vec<Address>,
    pub(crate) date: Option<DateTime<Utc>>,
    pub(crate) message_id: Option<String>,
    pub(crate) text_body: Option<String>,
    pub(crate) html_body: Option<String>,
    pub(crate) attachments: Vec<ParsedAttachment>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ParsedAttachment {
    pub(crate) filename: String,
    pub(crate) content_type: String,
    pub(crate) content_id: Option<String>,
    pub(crate) inline: bool,
    pub(crate) data: Vec<u8>,
}

pub(crate) trait MimeCodec: Send + Sync {
    fn parse(&self, message: &[u8]) -> Result<ParsedMime, MimeError>;
    fn build(&self, from: &Address, message: &OutgoingMessage) -> Result<Vec<u8>, MimeError>;
    fn build_reply(
        &self,
        from: &Address,
        message: &OutgoingMessage,
        _rfc_message_id: Option<&str>,
    ) -> Result<Vec<u8>, MimeError> {
        self.build(from, message)
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct ProductionMimeCodec;

impl MimeCodec for ProductionMimeCodec {
    fn parse(&self, raw: &[u8]) -> Result<ParsedMime, MimeError> {
        validate_message_size(raw.len(), MAX_MAIL_MESSAGE_BYTES)?;
        let message = MessageParser::default()
            .parse(raw)
            .ok_or(MimeError::MalformedMessage)?;
        let mut attachments = Vec::new();
        let mut attachment_bytes = 0;
        for part in message.attachments() {
            let contents = part.contents();
            reserve_attachment_budget(
                attachments.len(),
                &mut attachment_bytes,
                contents.len(),
                MAX_MIME_ATTACHMENTS,
                MAX_MAIL_ATTACHMENT_BYTES,
            )?;
            attachments.push(ParsedAttachment {
                filename: sanitize_filename(part.attachment_name()),
                content_type: part
                    .content_type()
                    .map(|value| {
                        format!(
                            "{}/{}",
                            value.c_type,
                            value.c_subtype.as_deref().unwrap_or("octet-stream")
                        )
                    })
                    .unwrap_or_else(|| "application/octet-stream".into()),
                content_id: part.content_id().map(str::to_owned),
                inline: part
                    .content_disposition()
                    .is_some_and(|value| value.c_type.eq_ignore_ascii_case("inline")),
                data: contents.to_vec(),
            });
        }
        Ok(ParsedMime {
            subject: message.subject().unwrap_or_default().to_owned(),
            from: message
                .from()
                .and_then(|value| value.first())
                .and_then(convert_addr),
            to: convert_addresses(message.to()),
            cc: convert_addresses(message.cc()),
            bcc: convert_addresses(message.bcc()),
            date: message
                .date()
                .and_then(|date| DateTime::from_timestamp(date.to_timestamp(), 0)),
            message_id: message.message_id().map(str::to_owned),
            text_body: message.body_text(0).map(|body| body.into_owned()),
            html_body: message.body_html(0).map(|body| body.into_owned()),
            attachments,
        })
    }

    fn build(&self, from: &Address, message: &OutgoingMessage) -> Result<Vec<u8>, MimeError> {
        production_build(from, message, None)
    }

    fn build_reply(
        &self,
        from: &Address,
        message: &OutgoingMessage,
        rfc_message_id: Option<&str>,
    ) -> Result<Vec<u8>, MimeError> {
        production_build(from, message, rfc_message_id)
    }
}

fn production_build(
    from: &Address,
    message: &OutgoingMessage,
    rfc_message_id: Option<&str>,
) -> Result<Vec<u8>, MimeError> {
    validate_address(from)?;
    for address in message
        .to
        .iter()
        .chain(message.cc.iter())
        .chain(message.bcc.iter())
    {
        validate_address(address)?;
    }
    validate_header(&message.subject)?;
    let mut builder = MessageBuilder::new()
        .from((from.name.clone(), from.address.clone()))
        .to(builder_addresses(&message.to))
        .subject(message.subject.clone());
    if !message.cc.is_empty() {
        builder = builder.cc(builder_addresses(&message.cc));
    }
    if let Some(message_id) = rfc_message_id {
        validate_header(message_id)?;
        let message_id = message_id
            .strip_prefix('<')
            .and_then(|value| value.strip_suffix('>'))
            .unwrap_or(message_id);
        builder = builder
            .in_reply_to(message_id.to_owned())
            .references(message_id.to_owned());
    }
    if let Some(text) = message.body_text.clone() {
        builder = builder.text_body(text);
    }
    if let Some(html) = message.body_html.clone() {
        builder = builder.html_body(html);
    }
    builder.write_to_vec().map_err(|_| MimeError::Build)
}

fn convert_addr(address: &mail_parser::Addr<'_>) -> Option<Address> {
    Some(Address {
        name: address.name.as_deref().unwrap_or_default().to_owned(),
        address: address.address.as_deref()?.to_owned(),
    })
}

fn convert_addresses(addresses: Option<&mail_parser::Address<'_>>) -> Vec<Address> {
    addresses
        .into_iter()
        .flat_map(mail_parser::Address::iter)
        .filter_map(convert_addr)
        .collect()
}

fn builder_addresses(addresses: &[Address]) -> Vec<(String, String)> {
    addresses
        .iter()
        .map(|address| (address.name.clone(), address.address.clone()))
        .collect()
}

pub(crate) fn sanitize_filename(filename: Option<&str>) -> String {
    let candidate = filename
        .and_then(|value| value.rsplit(['/', '\\']).next())
        .unwrap_or("attachment");
    let clean = candidate
        .chars()
        .filter(|character| !character.is_control())
        .take(240)
        .collect::<String>();
    if clean.is_empty() || clean == "." || clean == ".." {
        "attachment".into()
    } else {
        clean
    }
}

/// Dependency-free MIME codec used by the adapter seam and fixtures.
///
/// The production dependency list calls for `mail-parser` and `mail-builder`;
/// those can implement the same trait without changing provider behavior. This
/// implementation is intentionally conservative: malformed encodings are
/// rejected and header values containing newlines are never emitted.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct SafeMimeCodec;

impl MimeCodec for SafeMimeCodec {
    fn parse(&self, message: &[u8]) -> Result<ParsedMime, MimeError> {
        validate_message_size(message.len(), MAX_MAIL_MESSAGE_BYTES)?;
        let (raw_headers, body) = split_headers_body(message).ok_or(MimeError::MissingHeaders)?;
        let headers = parse_headers(raw_headers)?;
        let mut parsed = ParsedMime {
            subject: header(&headers, "subject").unwrap_or_default().to_owned(),
            from: header(&headers, "from").and_then(parse_single_address),
            to: header(&headers, "to")
                .map(parse_addresses)
                .unwrap_or_default(),
            cc: header(&headers, "cc")
                .map(parse_addresses)
                .unwrap_or_default(),
            bcc: header(&headers, "bcc")
                .map(parse_addresses)
                .unwrap_or_default(),
            date: header(&headers, "date")
                .and_then(|date| DateTime::parse_from_rfc2822(date).ok())
                .map(|date| date.with_timezone(&Utc)),
            message_id: header(&headers, "message-id").map(str::to_owned),
            ..ParsedMime::default()
        };
        let mut attachment_bytes = 0;
        parse_entity(&headers, body, &mut parsed, &mut attachment_bytes)?;
        Ok(parsed)
    }

    fn build(&self, from: &Address, message: &OutgoingMessage) -> Result<Vec<u8>, MimeError> {
        validate_address(from)?;
        for address in message
            .to
            .iter()
            .chain(message.cc.iter())
            .chain(message.bcc.iter())
        {
            validate_address(address)?;
        }
        validate_header(&message.subject)?;

        let mut output = String::new();
        push_header(&mut output, "From", &format_address(from));
        push_header(&mut output, "To", &format_addresses(&message.to));
        if !message.cc.is_empty() {
            push_header(&mut output, "Cc", &format_addresses(&message.cc));
        }
        // Bcc is deliberately excluded from serialized headers.
        push_header(&mut output, "Subject", &message.subject);
        push_header(&mut output, "Date", &Utc::now().to_rfc2822());
        push_header(
            &mut output,
            "Message-ID",
            &format!("<{}@quickmail.local>", Uuid::new_v4()),
        );
        push_header(&mut output, "MIME-Version", "1.0");

        match (&message.body_text, &message.body_html) {
            (Some(text), Some(html)) => {
                let boundary = format!("quickmail-alt-{}", Uuid::new_v4().simple());
                push_header(
                    &mut output,
                    "Content-Type",
                    &format!("multipart/alternative; boundary=\"{boundary}\""),
                );
                output.push_str("\r\n");
                append_text_part(&mut output, &boundary, "text/plain", text);
                append_text_part(&mut output, &boundary, "text/html", html);
                output.push_str("--");
                output.push_str(&boundary);
                output.push_str("--\r\n");
            }
            (Some(text), None) => append_single_body(&mut output, "text/plain", text),
            (None, Some(html)) => append_single_body(&mut output, "text/html", html),
            (None, None) => append_single_body(&mut output, "text/plain", ""),
        }
        Ok(output.into_bytes())
    }
}

fn split_headers_body(message: &[u8]) -> Option<(&[u8], &[u8])> {
    find_bytes(message, b"\r\n\r\n")
        .map(|index| (&message[..index], &message[index + 4..]))
        .or_else(|| {
            find_bytes(message, b"\n\n").map(|index| (&message[..index], &message[index + 2..]))
        })
}

fn parse_headers(raw: &[u8]) -> Result<BTreeMap<String, String>, MimeError> {
    let text = std::str::from_utf8(raw).map_err(|_| MimeError::InvalidHeaderEncoding)?;
    let normalized = text.replace("\r\n", "\n");
    let mut unfolded = Vec::<String>::new();
    for line in normalized.lines() {
        if line.starts_with([' ', '\t']) {
            let current = unfolded.last_mut().ok_or(MimeError::MalformedHeader)?;
            current.push(' ');
            current.push_str(line.trim());
        } else {
            unfolded.push(line.to_owned());
        }
    }
    let mut headers = BTreeMap::new();
    for line in unfolded {
        let (name, value) = line.split_once(':').ok_or(MimeError::MalformedHeader)?;
        headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
    }
    Ok(headers)
}

fn parse_entity(
    headers: &BTreeMap<String, String>,
    body: &[u8],
    parsed: &mut ParsedMime,
    attachment_bytes: &mut usize,
) -> Result<(), MimeError> {
    let content_type = header(headers, "content-type").unwrap_or("text/plain");
    let media_type = content_type
        .split(';')
        .next()
        .unwrap_or("text/plain")
        .trim()
        .to_ascii_lowercase();
    if media_type.starts_with("multipart/") {
        let boundary = parameter(content_type, "boundary").ok_or(MimeError::MissingBoundary)?;
        for part in split_multipart(body, &boundary) {
            if let Some((part_headers, part_body)) = split_headers_body(part) {
                let part_headers = parse_headers(part_headers)?;
                parse_entity(&part_headers, part_body, parsed, attachment_bytes)?;
            }
        }
        return Ok(());
    }

    let decoded = decode_body(
        body,
        header(headers, "content-transfer-encoding").unwrap_or("8bit"),
    )?;
    let disposition = header(headers, "content-disposition").unwrap_or("");
    let filename = parameter(disposition, "filename").or_else(|| parameter(content_type, "name"));
    let is_attachment = disposition.to_ascii_lowercase().starts_with("attachment")
        || filename.is_some()
        || (!media_type.starts_with("text/") && media_type != "message/rfc822");
    if is_attachment {
        reserve_attachment_budget(
            parsed.attachments.len(),
            attachment_bytes,
            decoded.len(),
            MAX_MIME_ATTACHMENTS,
            MAX_MAIL_ATTACHMENT_BYTES,
        )?;
        parsed.attachments.push(ParsedAttachment {
            filename: filename.unwrap_or_else(|| "attachment".to_owned()),
            content_type: media_type,
            content_id: header(headers, "content-id").map(str::to_owned),
            inline: disposition.to_ascii_lowercase().starts_with("inline"),
            data: decoded,
        });
    } else if media_type == "text/html" {
        parsed.html_body = Some(String::from_utf8_lossy(&decoded).into_owned());
    } else if media_type == "text/plain" {
        parsed.text_body = Some(String::from_utf8_lossy(&decoded).into_owned());
    }
    Ok(())
}

fn validate_message_size(size: usize, limit: usize) -> Result<(), MimeError> {
    if size > limit {
        Err(MimeError::MessageTooLarge)
    } else {
        Ok(())
    }
}

fn reserve_attachment_budget(
    current_count: usize,
    current_bytes: &mut usize,
    next_bytes: usize,
    count_limit: usize,
    byte_limit: usize,
) -> Result<(), MimeError> {
    let total_bytes = current_bytes
        .checked_add(next_bytes)
        .ok_or(MimeError::AttachmentLimitExceeded)?;
    if current_count >= count_limit || next_bytes > byte_limit || total_bytes > byte_limit {
        return Err(MimeError::AttachmentLimitExceeded);
    }
    *current_bytes = total_bytes;
    Ok(())
}

fn split_multipart<'a>(body: &'a [u8], boundary: &str) -> Vec<&'a [u8]> {
    let marker = format!("--{boundary}");
    let body_text = String::from_utf8_lossy(body);
    let mut offset = 0;
    let mut parts = Vec::new();
    for segment in body_text.split(&marker).skip(1) {
        if segment.starts_with("--") {
            break;
        }
        let trimmed = segment
            .strip_prefix("\r\n")
            .or_else(|| segment.strip_prefix('\n'))
            .unwrap_or(segment)
            .trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            continue;
        }
        if let Some(index) = find_bytes(&body[offset..], trimmed.as_bytes()) {
            let start = offset + index;
            parts.push(&body[start..start + trimmed.len()]);
            offset = start + trimmed.len();
        }
    }
    parts
}

fn parameter(value: &str, name: &str) -> Option<String> {
    value.split(';').skip(1).find_map(|part| {
        let (key, value) = part.trim().split_once('=')?;
        key.eq_ignore_ascii_case(name)
            .then(|| value.trim().trim_matches('"').to_owned())
    })
}

fn decode_body(body: &[u8], encoding: &str) -> Result<Vec<u8>, MimeError> {
    match encoding.trim().to_ascii_lowercase().as_str() {
        "base64" => decode_base64(body),
        "quoted-printable" => decode_quoted_printable(body),
        _ => Ok(body.to_vec()),
    }
}

fn decode_base64(input: &[u8]) -> Result<Vec<u8>, MimeError> {
    let mut accumulator = 0_u32;
    let mut bits = 0_u8;
    let mut output = Vec::with_capacity(input.len() * 3 / 4);
    for byte in input
        .iter()
        .copied()
        .filter(|byte| !byte.is_ascii_whitespace())
    {
        if byte == b'=' {
            break;
        }
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return Err(MimeError::InvalidBase64),
        };
        accumulator = (accumulator << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
            accumulator &= (1 << bits) - 1;
        }
    }
    Ok(output)
}

fn decode_quoted_printable(input: &[u8]) -> Result<Vec<u8>, MimeError> {
    let mut output = Vec::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        if input[index] != b'=' {
            output.push(input[index]);
            index += 1;
            continue;
        }
        if input.get(index + 1..index + 3) == Some(b"\r\n") {
            index += 3;
            continue;
        }
        if input.get(index + 1) == Some(&b'\n') {
            index += 2;
            continue;
        }
        let high = input.get(index + 1).and_then(|byte| hex(*byte));
        let low = input.get(index + 2).and_then(|byte| hex(*byte));
        output.push(
            high.zip(low)
                .map(|(h, l)| h << 4 | l)
                .ok_or(MimeError::InvalidQuotedPrintable)?,
        );
        index += 3;
    }
    Ok(output)
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn parse_addresses(value: &str) -> Vec<Address> {
    value.split(',').filter_map(parse_single_address).collect()
}

fn parse_single_address(value: &str) -> Option<Address> {
    let value = value.trim();
    if let Some((name, address)) = value.rsplit_once('<') {
        return Some(Address {
            name: name.trim().trim_matches('"').to_owned(),
            address: address.trim_end_matches('>').trim().to_owned(),
        });
    }
    value.contains('@').then(|| Address {
        name: String::new(),
        address: value.to_owned(),
    })
}

fn append_single_body(output: &mut String, media_type: &str, body: &str) {
    push_header(
        output,
        "Content-Type",
        &format!("{media_type}; charset=utf-8"),
    );
    push_header(output, "Content-Transfer-Encoding", "base64");
    output.push_str("\r\n");
    output.push_str(&wrap_base64(body.as_bytes()));
}

fn append_text_part(output: &mut String, boundary: &str, media_type: &str, body: &str) {
    output.push_str("--");
    output.push_str(boundary);
    output.push_str("\r\n");
    push_header(
        output,
        "Content-Type",
        &format!("{media_type}; charset=utf-8"),
    );
    push_header(output, "Content-Transfer-Encoding", "base64");
    output.push_str("\r\n");
    output.push_str(&wrap_base64(body.as_bytes()));
}

fn wrap_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        encoded.push(TABLE[((value >> 18) & 63) as usize] as char);
        encoded.push(TABLE[((value >> 12) & 63) as usize] as char);
        encoded.push(if chunk.len() > 1 {
            TABLE[((value >> 6) & 63) as usize] as char
        } else {
            '='
        });
        encoded.push(if chunk.len() > 2 {
            TABLE[(value & 63) as usize] as char
        } else {
            '='
        });
    }
    let mut wrapped = String::new();
    for line in encoded.as_bytes().chunks(76) {
        wrapped.push_str(std::str::from_utf8(line).expect("base64 is ASCII"));
        wrapped.push_str("\r\n");
    }
    wrapped
}

fn format_addresses(addresses: &[Address]) -> String {
    addresses
        .iter()
        .map(format_address)
        .collect::<Vec<_>>()
        .join(", ")
}

fn format_address(address: &Address) -> String {
    if address.name.is_empty() {
        address.address.clone()
    } else {
        format!(
            "\"{}\" <{}>",
            address.name.replace('"', "\\\""),
            address.address
        )
    }
}

fn validate_address(address: &Address) -> Result<(), MimeError> {
    validate_header(&address.name)?;
    validate_header(&address.address)?;
    if !address.address.contains('@') {
        return Err(MimeError::InvalidAddress);
    }
    Ok(())
}

fn validate_header(value: &str) -> Result<(), MimeError> {
    if value.contains(['\r', '\n']) {
        Err(MimeError::HeaderInjection)
    } else {
        Ok(())
    }
}

fn push_header(output: &mut String, name: &str, value: &str) {
    output.push_str(name);
    output.push_str(": ");
    output.push_str(value);
    output.push_str("\r\n");
}

fn header<'a>(headers: &'a BTreeMap<String, String>, name: &str) -> Option<&'a str> {
    headers.get(name).map(String::as_str)
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[derive(Debug, Error, PartialEq, Eq)]
pub(crate) enum MimeError {
    #[error("message exceeds the configured MIME size limit")]
    MessageTooLarge,
    #[error("message attachments exceed the configured MIME limits")]
    AttachmentLimitExceeded,
    #[error("message could not be parsed as RFC 5322/MIME")]
    MalformedMessage,
    #[error("message could not be serialized as RFC 5322/MIME")]
    Build,
    #[error("message is missing its header/body separator")]
    MissingHeaders,
    #[error("message header is malformed")]
    MalformedHeader,
    #[error("message header is not UTF-8")]
    InvalidHeaderEncoding,
    #[error("multipart entity has no boundary")]
    MissingBoundary,
    #[error("invalid base64 body")]
    InvalidBase64,
    #[error("invalid quoted-printable body")]
    InvalidQuotedPrintable,
    #[error("header value contains a newline")]
    HeaderInjection,
    #[error("invalid email address")]
    InvalidAddress,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_folded_headers_and_multipart_bodies() {
        let raw = b"From: Alice <alice@example.com>\r\nTo: Bob <bob@example.com>\r\nSubject: A folded\r\n subject\r\nContent-Type: multipart/alternative; boundary=\"b\"\r\n\r\n--b\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nhello=20world\r\n--b\r\nContent-Type: text/html\r\nContent-Transfer-Encoding: base64\r\n\r\nPHA+aGk8L3A+\r\n--b--\r\n";

        let message = SafeMimeCodec.parse(raw).unwrap();
        assert_eq!(message.subject, "A folded subject");
        assert_eq!(message.text_body.as_deref(), Some("hello world"));
        assert_eq!(message.html_body.as_deref(), Some("<p>hi</p>"));
    }

    #[test]
    fn build_omits_bcc_and_round_trips_bodies() {
        let outgoing = OutgoingMessage {
            draft_id: None,
            account_id: "a".into(),
            to: vec![Address {
                name: "Bob".into(),
                address: "bob@example.com".into(),
            }],
            cc: Vec::new(),
            bcc: vec![Address {
                name: String::new(),
                address: "hidden@example.com".into(),
            }],
            subject: "Hello".into(),
            body_text: Some("plain".into()),
            body_html: Some("<b>html</b>".into()),
            in_reply_to: None,
        };
        let raw = SafeMimeCodec
            .build(
                &Address {
                    name: "Alice".into(),
                    address: "alice@example.com".into(),
                },
                &outgoing,
            )
            .unwrap();
        let text = String::from_utf8_lossy(&raw);
        assert!(!text.contains("hidden@example.com"));

        let parsed = SafeMimeCodec.parse(&raw).unwrap();
        assert_eq!(parsed.text_body.as_deref(), Some("plain"));
        assert_eq!(parsed.html_body.as_deref(), Some("<b>html</b>"));
    }

    #[test]
    fn builder_rejects_header_injection() {
        let outgoing = OutgoingMessage {
            draft_id: None,
            account_id: "a".into(),
            to: vec![Address {
                name: String::new(),
                address: "bob@example.com".into(),
            }],
            cc: Vec::new(),
            bcc: Vec::new(),
            subject: "hello\r\nBcc: stolen@example.com".into(),
            body_text: None,
            body_html: None,
            in_reply_to: None,
        };
        assert_eq!(
            SafeMimeCodec
                .build(
                    &Address {
                        name: String::new(),
                        address: "alice@example.com".into()
                    },
                    &outgoing
                )
                .unwrap_err(),
            MimeError::HeaderInjection
        );
    }

    #[test]
    fn production_codec_decodes_encoded_words_and_sanitizes_names() {
        let raw = b"From: =?UTF-8?Q?J=C3=B6rg?= <joerg@example.com>\r\nSubject: =?UTF-8?B?R3LDvMOfZQ==?=\r\nContent-Type: application/octet-stream; name=\"../secret.bin\"\r\nContent-Disposition: attachment; filename=\"../secret.bin\"\r\nContent-Transfer-Encoding: base64\r\n\r\nAQID\r\n";
        let parsed = ProductionMimeCodec.parse(raw).unwrap();
        assert_eq!(parsed.subject, "Grüße");
        assert_eq!(parsed.from.unwrap().name, "Jörg");
        assert_eq!(parsed.attachments[0].filename, "secret.bin");
        assert_eq!(parsed.attachments[0].data, vec![1, 2, 3]);
    }

    #[test]
    fn production_limits_reject_oversized_messages_without_parsing() {
        assert_eq!(
            validate_message_size(MAX_MAIL_MESSAGE_BYTES + 1, MAX_MAIL_MESSAGE_BYTES),
            Err(MimeError::MessageTooLarge)
        );
        assert_eq!(
            validate_message_size(MAX_MAIL_MESSAGE_BYTES, MAX_MAIL_MESSAGE_BYTES),
            Ok(())
        );
    }

    #[test]
    fn decoded_attachment_budget_limits_count_and_total_bytes() {
        let mut total = 0;
        reserve_attachment_budget(0, &mut total, 3, 2, 5).unwrap();
        assert_eq!(total, 3);
        assert_eq!(
            reserve_attachment_budget(1, &mut total, 3, 2, 5),
            Err(MimeError::AttachmentLimitExceeded)
        );
        assert_eq!(total, 3, "a rejected part must not consume budget");
        assert_eq!(
            reserve_attachment_budget(2, &mut total, 1, 2, 5),
            Err(MimeError::AttachmentLimitExceeded)
        );
    }

    #[test]
    fn production_reply_emits_threading_headers_with_rfc_message_id() {
        let outgoing = OutgoingMessage {
            draft_id: None,
            account_id: "a".into(),
            to: vec![Address {
                name: "Bob".into(),
                address: "bob@example.com".into(),
            }],
            cc: Vec::new(),
            bcc: Vec::new(),
            subject: "Re: hello".into(),
            body_text: Some("reply".into()),
            body_html: None,
            in_reply_to: Some("account:native".into()),
        };
        let raw = ProductionMimeCodec
            .build_reply(
                &Address {
                    name: "Alice".into(),
                    address: "alice@example.com".into(),
                },
                &outgoing,
                Some("<original@example.com>"),
            )
            .unwrap();
        let text = String::from_utf8(raw).unwrap();
        assert!(
            text.contains("In-Reply-To: <original@example.com>"),
            "{text}"
        );
        assert!(
            text.contains("References: <original@example.com>"),
            "{text}"
        );
        assert!(!text.contains("account:native"));
    }
}
