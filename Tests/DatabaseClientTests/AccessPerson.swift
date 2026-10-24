import DatabaseKit

@Persistable
struct AccessPerson {
    var id: String = ""
    var name: String = ""
    var isActive: Bool = false
}
