import Foundation
import Contacts

struct AppleContactsTools {
    private var store: CNContactStore { ApplePermissionManager.shared.contactStore }

    private static let detailKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactInstantMessageAddressesKey as CNKeyDescriptor,
        CNContactIdentifierKey as CNKeyDescriptor,
    ]

    private static let searchKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactIdentifierKey as CNKeyDescriptor,
    ]

    func searchContacts(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureContactsAccess() { return err }

        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "[Error] Missing required parameter: query"
        }

        do {
            let predicate = CNContact.predicateForContacts(matchingName: query)
            var contacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.searchKeys)

            if contacts.isEmpty {
                if let phoneDigits = query.components(separatedBy: CharacterSet.decimalDigits.inverted).joined() as String?,
                   phoneDigits.count >= 3 {
                    let phonePredicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
                    contacts = try store.unifiedContacts(matching: phonePredicate, keysToFetch: Self.searchKeys)
                }
            }

            if contacts.isEmpty {
                return "(No contacts found matching '\(query)')"
            }

            let limit = min(contacts.count, 30)
            let result = contacts.prefix(limit).map { c in
                var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = c.organizationName.isEmpty ? "(No name)" : c.organizationName }

                var line = "- **\(name)**"
                if !c.organizationName.isEmpty && !name.contains(c.organizationName) {
                    line += " (\(c.organizationName))"
                }
                if let phone = c.phoneNumbers.first {
                    line += " | Phone: \(phone.value.stringValue)"
                }
                if let email = c.emailAddresses.first {
                    line += " | Email: \(email.value as String)"
                }
                line += "\n  ID: \(c.identifier)"
                return line
            }.joined(separator: "\n")

            let suffix = contacts.count > limit ? "\n(... and \(contacts.count - limit) more)" : ""
            return result + suffix
        } catch {
            return "[Error] Failed to search contacts: \(error.localizedDescription)"
        }
    }

    func getContactDetail(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureContactsAccess() { return err }

        guard let contactId = arguments["contact_id"] as? String else {
            return "[Error] Missing required parameter: contact_id"
        }

        do {
            let predicate = CNContact.predicateForContacts(withIdentifiers: [contactId])
            guard let contact = try store.unifiedContacts(matching: predicate, keysToFetch: Self.detailKeys).first else {
                return "[Error] Contact not found with id: \(contactId)"
            }

            var lines: [String] = []

            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            lines.append("**\(name.isEmpty ? "(No name)" : name)**")

            if !contact.organizationName.isEmpty { lines.append("Organization: \(contact.organizationName)") }
            if !contact.jobTitle.isEmpty { lines.append("Job Title: \(contact.jobTitle)") }
            if !contact.departmentName.isEmpty { lines.append("Department: \(contact.departmentName)") }

            if !contact.phoneNumbers.isEmpty {
                lines.append("Phones:")
                for p in contact.phoneNumbers {
                    let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: p.label ?? "")
                    lines.append("  - \(label.isEmpty ? "Other" : label): \(p.value.stringValue)")
                }
            }

            if !contact.emailAddresses.isEmpty {
                lines.append("Emails:")
                for e in contact.emailAddresses {
                    let label = CNLabeledValue<NSString>.localizedString(forLabel: e.label ?? "")
                    lines.append("  - \(label.isEmpty ? "Other" : label): \(e.value as String)")
                }
            }

            if !contact.postalAddresses.isEmpty {
                lines.append("Addresses:")
                for a in contact.postalAddresses {
                    let label = CNLabeledValue<CNPostalAddress>.localizedString(forLabel: a.label ?? "")
                    let addr = CNPostalAddressFormatter.string(from: a.value, style: .mailingAddress)
                    lines.append("  - \(label.isEmpty ? "Other" : label): \(addr.replacingOccurrences(of: "\n", with: ", "))")
                }
            }

            if let birthday = contact.birthday, let date = Calendar.current.date(from: birthday) {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                lines.append("Birthday: \(f.string(from: date))")
            }

            if !contact.urlAddresses.isEmpty {
                lines.append("URLs:")
                for u in contact.urlAddresses {
                    lines.append("  - \(u.value as String)")
                }
            }

            if !contact.note.isEmpty {
                lines.append("Notes: \(contact.note)")
            }

            lines.append("ID: \(contact.identifier)")

            return lines.joined(separator: "\n")
        } catch {
            return "[Error] Failed to get contact detail: \(error.localizedDescription)"
        }
    }
}
