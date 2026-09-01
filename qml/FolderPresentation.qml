pragma Singleton

import QtQuick

QtObject {
    function cleanName(value) {
        let label = String(value || "").trim()
        let previous = ""
        do {
            previous = label
            label = label.replace(/^\s*\[(?:gmail|google\s+mail)\]\s*(?:[\/\\]+\s*)?/i, "").trim()
        } while (label !== previous)
        label = label.replace(/\s*[\/\\]+\s*/g, " / ")
        label = label.replace(/^(?:\s*\/\s*)+|(?:\s*\/\s*)+$/g, "")
        return label.replace(/\s{2,}/g, " ").trim()
    }

    function mailboxRole(folder) {
        const explicitRole = String(folder && folder.role || "").trim().toLowerCase()
        if (explicitRole !== "") return explicitRole

        const folderId = String(folder && (folder.id || folder.folder_id) || "")
            .trim().toLowerCase()
        if (["inbox", "unread", "starred", "drafts", "sent", "archive", "trash", "spam"]
                .indexOf(folderId) >= 0)
            return folderId

        const rawName = String(folder && (folder.name || folder.display_name) || folderId)
        const key = cleanName(rawName).toLowerCase().replace(/[._-]+/g, " ")
            .replace(/\s+/g, " ")
        if (key === "inbox") return "inbox"
        if (key === "unread") return "unread"
        if (key === "starred" || key === "flagged") return "starred"
        if (key === "draft" || key === "drafts") return "drafts"
        if (key === "sent" || key === "sent mail" || key === "sent items") return "sent"
        if (key === "archive" || key === "all" || key === "all mail") return "archive"
        if (key === "trash" || key === "bin" || key === "deleted"
                || key === "deleted items") return "trash"
        if (key === "spam" || key === "junk" || key === "junk email") return "spam"
        return ""
    }

    function displayName(folder) {
        const folderId = String(folder && (folder.id || folder.folder_id) || "")
        const rawName = String(folder && (folder.name || folder.display_name) || folderId)
        const label = cleanName(rawName)
        const key = label.toLowerCase().replace(/[._-]+/g, " ").replace(/\s+/g, " ")
        if (key === "inbox") return "Inbox"
        if (key === "unread") return "Unread"
        if (key === "starred") return "Starred"
        if (key === "draft" || key === "drafts") return "Drafts"
        if (key === "sent" || key === "sent mail" || key === "sent items") return "Sent"
        if (key === "archive") return "Archive"
        if (key === "all" || key === "all mail") return "All Mail"
        if (key === "trash" || key === "bin" || key === "deleted"
                || key === "deleted items") return "Trash"
        if (key === "spam" || key === "junk" || key === "junk email") return "Spam"
        if (label !== "") return label

        const role = mailboxRole(folder)
        if (role === "inbox") return "Inbox"
        if (role === "unread") return "Unread"
        if (role === "starred") return "Starred"
        if (role === "drafts") return "Drafts"
        if (role === "sent") return "Sent"
        if (role === "archive") return "Archive"
        if (role === "trash") return "Trash"
        if (role === "spam") return "Spam"
        return "Mail"
    }

    function iconName(folder) {
        const explicitIcon = String(folder && folder.icon || "")
        if (explicitIcon !== "") return explicitIcon
        const role = mailboxRole(folder)
        if (role === "inbox") return "inbox"
        if (role === "unread") return "unread"
        if (role === "starred") return "star"
        if (role === "drafts") return "drafts"
        if (role === "sent") return "sent"
        if (role === "archive") return "archive"
        if (role === "trash") return "trash"
        if (role === "spam") return "error"
        return "folder"
    }
}
