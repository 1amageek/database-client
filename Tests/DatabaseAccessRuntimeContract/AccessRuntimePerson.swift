import DatabaseKit

@Persistable
public struct AccessRuntimePerson {
    public var id: String = ""
    public var name: String = ""
    public var isActive: Bool = false
}
