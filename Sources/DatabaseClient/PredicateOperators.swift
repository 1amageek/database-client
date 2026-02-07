import Core
import QueryIR

// MARK: - KeyPath → QueryIR.Expression operators

/// Builds a QueryIR.Expression from KeyPath comparison
///
/// Usage:
/// ```swift
/// .where(\.age > 20)
/// .where(\.name == "Alice")
/// .where(\.age > 20 && \.name != "Admin")
/// ```

/// Helper to convert a field name and FieldValue to a column/literal expression pair
private func fieldExpression<T: Persistable, V: FieldValueConvertible>(
    _ keyPath: KeyPath<T, V>, _ value: V
) -> (QueryIR.Expression, QueryIR.Expression) {
    let col = QueryIR.Expression.column(ColumnRef(column: T.fieldName(for: keyPath)))
    let lit = fieldValueToLiteral(value.toFieldValue())
    return (col, .literal(lit))
}

/// Convert FieldValue to QueryIR.Literal
private func fieldValueToLiteral(_ fv: FieldValue) -> Literal {
    switch fv {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int64(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .data(let d): return .binary(d)
    case .array(let arr): return .array(arr.map { fieldValueToLiteral($0) })
    }
}

public func == <T: Persistable, V: FieldValueConvertible>(
    lhs: KeyPath<T, V>, rhs: V
) -> QueryIR.Expression {
    let (col, lit) = fieldExpression(lhs, rhs)
    return .equal(col, lit)
}

public func != <T: Persistable, V: FieldValueConvertible>(
    lhs: KeyPath<T, V>, rhs: V
) -> QueryIR.Expression {
    let (col, lit) = fieldExpression(lhs, rhs)
    return .notEqual(col, lit)
}

public func < <T: Persistable, V: FieldValueConvertible & Comparable>(
    lhs: KeyPath<T, V>, rhs: V
) -> QueryIR.Expression {
    let (col, lit) = fieldExpression(lhs, rhs)
    return .lessThan(col, lit)
}

public func <= <T: Persistable, V: FieldValueConvertible & Comparable>(
    lhs: KeyPath<T, V>, rhs: V
) -> QueryIR.Expression {
    let (col, lit) = fieldExpression(lhs, rhs)
    return .lessThanOrEqual(col, lit)
}

public func > <T: Persistable, V: FieldValueConvertible & Comparable>(
    lhs: KeyPath<T, V>, rhs: V
) -> QueryIR.Expression {
    let (col, lit) = fieldExpression(lhs, rhs)
    return .greaterThan(col, lit)
}

public func >= <T: Persistable, V: FieldValueConvertible & Comparable>(
    lhs: KeyPath<T, V>, rhs: V
) -> QueryIR.Expression {
    let (col, lit) = fieldExpression(lhs, rhs)
    return .greaterThanOrEqual(col, lit)
}

// MARK: - Logical operators
// &&, ||, ! are defined in QueryIR.Expression as static operators.
// Re-exported here via `import QueryIR`.
