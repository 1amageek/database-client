import DatabaseKit
import DatabaseWire

#if DATABASE_CLIENT_MULTI_BASE
public typealias AccessResult = QueryResult<RowStream, GraphStream, QueryBooleanResult>
#else
public typealias AccessResult = QueryResult<RowStream, GraphStream, Bool>
#endif
