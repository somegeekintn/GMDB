//
//  GMDB.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Foundation
import OSLog

let gmdbLog = Logger(subsystem: "GMDB", category: "general")

public enum GMDBError: Error, Equatable {
    case sql(Int32, String)
    case misconfigured

    public var localizedDescription: String {
        switch self {
        case let .sql(_, message):   message
        case .misconfigured:        "Database is misconfigured"
        }
    }

    public static func == (lhs: GMDBError, rhs: GMDBError) -> Bool {
        switch (lhs, rhs) {
            case let (.sql(lhsCode, _), .sql(rhsCode, _)):  lhsCode == rhsCode
            case (.misconfigured, .misconfigured):          true
            default:                                        false
        }
    }
}

public typealias SQLFunction = (OpaquePointer?, Int32, [OpaquePointer?]) -> Void
final class SQLFunctionBox {
    let block: SQLFunction

    init(_ block: @escaping SQLFunction) {
        self.block = block
    }
}

public typealias ExecuteStatementsCallback = ([String: String]) -> Int32
final class ExecuteStatementsCallbackBox {
    let block: ExecuteStatementsCallback
    init(_ block: @escaping ExecuteStatementsCallback) {
        self.block = block
    }
}

public enum GMDBCheckpointMode: Int32 {
    case passive    = 0  // SQLITE_CHECKPOINT_PASSIVE
    case full       = 1  // SQLITE_CHECKPOINT_FULL
    case restart    = 2  // SQLITE_CHECKPOINT_RESTART
    case truncate   = 3  // SQLITE_CHECKPOINT_TRUNCATE
}

public enum SQLiteValueType: Int32 {
    case integer = 1  // SQLITE_INTEGER
    case float   = 2  // SQLITE_FLOAT
    case text    = 3  // SQLITE_TEXT
    case blob    = 4  // SQLITE_BLOB
    case null    = 5  // SQLITE_NULL
}

