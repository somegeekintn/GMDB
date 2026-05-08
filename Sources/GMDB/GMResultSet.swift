//
//  GMResultSet.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Foundation
import SQLite3

class GMResultSet: NSObject {
    var parentDB: GMDatabase?
    var statement: GMStatement?
    var shouldAutoClose: Bool = false
    var query: String?

    private var _columnNameToIndexMap: [String: Int32]?

    var sqlStatement: OpaquePointer? { statement?.statement }

    var columnNameToIndexMap: [String: Int32] {
        return _columnNameToIndexMap ?? {
            let columnCount = sqlite3_column_count(sqlStatement);
            var result: [String: Int32] = [:]

            for columnIdx in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(sqlStatement, columnIdx)).lowercased()
                result[name] = columnIdx
            }
            _columnNameToIndexMap = result
            return result
        }()
    }

    var hasAnotherRow:  Bool {
        guard let db = parentDB?.sqliteHandle else { return false }

        return sqlite3_errcode(db) == SQLITE_ROW
    }

    static func resultSet(with statement: GMStatement, usingParentDatabase aDB: GMDatabase, shouldAutoClose: Bool) -> GMResultSet {
        GMResultSet(parentDB: aDB, statement: statement, shouldAutoClose: shouldAutoClose)
    }

    init(parentDB: GMDatabase, statement: GMStatement, shouldAutoClose: Bool) {
        self.parentDB = parentDB
        self.statement = statement
        self.shouldAutoClose = shouldAutoClose

        assert(!statement.inUse)
        statement.inUse = true
    }

    deinit {
        close()
    }
    
    func close() {
        statement?.reset()
        statement = nil

        parentDB?.resultSetDidClose(self)
        parentDB = nil
    }

    func resultDictionary() -> [String: Any]? {
        let num_cols = sqlite3_data_count(sqlStatement)
        guard num_cols > 0 else {
            gmdbLog.error("Warning: There seem to be no columns in this set.")
            return nil
        }

        var dict = Dictionary<String, Any>(minimumCapacity: Int(num_cols))
        let columnCount = sqlite3_column_count(sqlStatement)

        for columnIdx in 0..<columnCount {
            let columnName = String(cString: sqlite3_column_name(sqlStatement, columnIdx))
            let objectValue = objectFor(columnIndex: columnIdx)

            dict[columnName] = objectValue
        }

        return dict
    }

    @discardableResult
    func next() -> Bool {
        (try? nextWithError()) == true
    }

    func step() throws -> Bool {
        try internalStep() == SQLITE_DONE
    }

    func nextWithError() throws -> Bool {
        let rc = try internalStep()

        return rc == SQLITE_ROW
    }

    func internalStep() throws -> Int32 {
        guard let parentDB else { throw GMDBError.sql(SQLITE_MISUSE, "parentDB does not exist") }
        let rc = sqlite3_step(sqlStatement)

        switch rc {
        case SQLITE_BUSY, SQLITE_LOCKED:
            gmdbLog.error("Database busy (\(parentDB.databasePath ?? "N/A")")
            throw parentDB.lastError
        case SQLITE_DONE, SQLITE_ROW:
            // all is well, let's return.
            break
        case SQLITE_ERROR, SQLITE_MISUSE:
            gmdbLog.error("Error calling sqlite3_step (\(rc): \(parentDB.lastErrorMessage) rs")
            throw parentDB.lastError
        case SQLITE_MISUSE:
            gmdbLog.error("Error calling sqlite3_step (\(rc): \(parentDB.lastErrorMessage) rs")
            throw parentDB.lastError
        default:
            // wtf?
            gmdbLog.error("Unknown error calling sqlite3_step (\(rc): \(parentDB.lastErrorMessage) rs")
            throw parentDB.lastError
        }

        if rc != SQLITE_ROW && shouldAutoClose {
            close()
        }

        return rc
    }

    func columnIndexFor(column columnName: String) -> Int32 {
        if let n = columnNameToIndexMap[columnName.lowercased()] {
            return n
        }

        gmdbLog.warning("Warning: I could not find the column named '\(columnName)'.")

        return -1
    }

    func validate(columnIndex: Int32) -> Bool {
        !(columnIndex < 0 || sqlite3_column_type(sqlStatement, columnIndex) == SQLITE_NULL || columnIndex >= sqlite3_column_count(sqlStatement))
    }

    func intFor(column columnName: String) -> Int16 {
        intFor(columnIndex: columnIndexFor(column: columnName))
    }

    func intFor(columnIndex: Int32) -> Int16 {
        Int16(sqlite3_column_int(sqlStatement, columnIndex))
    }

    func longFor(column columnName: String) -> Int32 {
        longFor(columnIndex: columnIndexFor(column: columnName))
    }

    func longFor(columnIndex: Int32) -> Int32 {
        sqlite3_column_int(sqlStatement, columnIndex)
    }

    func longLongIntFor(column columnName: String) -> Int64 {
        longLongIntFor(columnIndex: columnIndexFor(column: columnName))
    }

    func longLongIntFor(columnIndex: Int32) -> Int64 {
        sqlite3_column_int64(sqlStatement, columnIndex)
    }

    func unsignedLongFor(column columnName: String) -> UInt32 {
        unsignedLongFor(columnIndex: columnIndexFor(column: columnName))
    }

    func unsignedLongFor(columnIndex: Int32) -> UInt32 {
        UInt32(bitPattern: longFor(columnIndex: columnIndex))
    }

    func unsignedLongLongIntFor(column columnName: String) -> UInt64 {
        unsignedLongLongIntFor(columnIndex: columnIndexFor(column: columnName))
    }

    func unsignedLongLongIntFor(columnIndex: Int32) -> UInt64 {
        UInt64(bitPattern: longLongIntFor(columnIndex: columnIndex))
    }

    func boolFor(column columnName: String) -> Bool {
        boolFor(columnIndex: columnIndexFor(column: columnName))
    }

    func boolFor(columnIndex: Int32) -> Bool {
        intFor(columnIndex: columnIndex) != 0
    }

    func doubleFor(column columnName: String) -> Double {
        doubleFor(columnIndex: columnIndexFor(column: columnName))
    }

    func doubleFor(columnIndex: Int32) -> Double {
        sqlite3_column_double(sqlStatement, columnIndex)
    }

    func stringFor(column columnName: String) -> String? {
        stringFor(columnIndex: columnIndexFor(column: columnName))
    }

    func stringFor(columnIndex: Int32) -> String? {
        guard validate(columnIndex: columnIndex) else { return nil }

        return String(cString: sqlite3_column_text(sqlStatement, columnIndex))
    }

    func dateFor(column columnName: String) -> Date? {
        dateFor(columnIndex: columnIndexFor(column: columnName))
    }

    func dateFor(columnIndex: Int32) -> Date? {
        guard validate(columnIndex: columnIndex) else { return nil }

        if let dateFormat = parentDB?.dateFormat {
            return stringFor(columnIndex: columnIndex).flatMap { dateFormat.date(from: $0) }
        }
        else {
            return Date(timeIntervalSince1970: doubleFor(columnIndex: columnIndex))
        }
    }

    func dataFor(column columnName: String) -> Data? {
        dataFor(columnIndex: columnIndexFor(column: columnName))
    }

    func dataFor(columnIndex: Int32) -> Data? {
        guard validate(columnIndex: columnIndex) else { return nil }
        let dataBuffer = sqlite3_column_blob(sqlStatement, columnIndex)
        let dataSize = sqlite3_column_bytes(sqlStatement, columnIndex)

        return dataBuffer.map { Data(bytes: $0, count: Int(dataSize)) }
    }

    func dataNoCopyFor(column columnName: String) -> Data? {
        dataNoCopyFor(columnIndex: columnIndexFor(column: columnName))
    }

    func dataNoCopyFor(columnIndex: Int32) -> Data? {
        guard validate(columnIndex: columnIndex) else { return nil }
        let dataBuffer = sqlite3_column_blob(sqlStatement, columnIndex)
        let dataSize = sqlite3_column_bytes(sqlStatement, columnIndex)

        return dataBuffer.map { Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0), count: Int(dataSize), deallocator: .none) }
    }

    func columnIndexIsNull(columnIndex: Int32) -> Bool {
        sqlite3_column_type(sqlStatement, columnIndex) == SQLITE_NULL
    }

    func columnIsNull(column columnName: String) -> Bool {
        return columnIndexIsNull(columnIndex: columnIndexFor(column: columnName))
    }

    func utf8StringFor(columnIndex: Int32) -> UnsafePointer<UInt8>? {
        guard validate(columnIndex: columnIndex) else { return nil }

        return sqlite3_column_text(sqlStatement, columnIndex);
    }

    func utf8StringFor(column columnName: String) -> UnsafePointer<UInt8>? {
        utf8StringFor(columnIndex: columnIndexFor(column: columnName))
    }

    func objectFor(columnIndex: Int32) -> Any? {
        guard columnIndex >= 0 && columnIndex < sqlite3_column_count(sqlStatement) else { return nil }
        let columnType = sqlite3_column_type(sqlStatement, columnIndex);
        let returnValue: Any?

        switch columnType {
        case SQLITE_INTEGER:    returnValue = longLongIntFor(columnIndex: columnIndex)
        case SQLITE_FLOAT:      returnValue = doubleFor(columnIndex: columnIndex)
        case SQLITE_BLOB:       returnValue = dataFor(columnIndex: columnIndex)
        default:                returnValue = stringFor(columnIndex: columnIndex)
        }

        return returnValue ?? NSNull()
    }

    func objectFor(column columnName: String) -> Any? {
        objectFor(columnIndex: columnIndexFor(column: columnName))
    }

    func columnNameFor(columnIndex: Int32) -> String {
        return String(cString: sqlite3_column_name(sqlStatement, columnIndex))
    }

    subscript (columnIndex: Int32) -> Any? {
        objectFor(columnIndex: columnIndex)
    }

    subscript (columnName: String) -> Any? {
        objectFor(column: columnName)
    }

    func bind(with arguments: GMDatabase.Arguments) -> Bool {
        guard let statement else { return false }
        guard let sqlStatement = statement.statement else { return false }

        statement.reset()
        return parentDB?.bindStatement(pStmt: sqlStatement, arguments: arguments) ?? false
    }

    func bind(with array: [Any?]) -> Bool {
        bind(with: .array(array))
    }

    func bind(with dictionary: [String: Any?]) -> Bool {
        bind(with: .dictionary(dictionary))
    }
}
