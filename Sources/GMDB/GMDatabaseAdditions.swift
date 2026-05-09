//
//  GMDatabaseAdditions.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 5/8/26.
//

import Foundation

public extension GMDatabase {
    enum Arguments {
        case array([Any?])
        case dictionary([String: Any?])
    }
}

public extension GMDatabase {
    func result<T>(for query: String, fallback: T, sel: (GMResultSet, Int32) -> T, _ arguments: [Any?]) -> T {
        guard let resultSet = executeQuery(query, arguments) else { return fallback }
        guard resultSet.next() else { return fallback }
        let result = sel(resultSet, 0)

        resultSet.close()

        return result
    }

    func string(for query: String, _ arguments: Any?...) -> String? {
        return result(for: query, fallback: nil, sel: { $0.stringFor(columnIndex: $1)}, arguments)
    }

    func int(for query: String, _ arguments: Any?...) -> Int16 {
        return result(for: query, fallback: 0, sel: { $0.intFor(columnIndex: $1)}, arguments)
    }

    func long(for query: String, _ arguments: Any?...) -> Int32 {
        return result(for: query, fallback: 0, sel: { $0.longFor(columnIndex: $1)}, arguments)
    }

    func bool(for query: String, _ arguments: Any?...) -> Bool {
        return result(for: query, fallback: false, sel: { $0.boolFor(columnIndex: $1)}, arguments)
    }

    func double(for query: String, _ arguments: Any?...) -> Double {
        return result(for: query, fallback: 0.0, sel: { $0.doubleFor(columnIndex: $1)}, arguments)
    }

    func data(for query: String, _ arguments: Any?...) -> Data? {
        return result(for: query, fallback: nil, sel: { $0.dataFor(columnIndex: $1)}, arguments)
    }

    func date(for query: String, _ arguments: Any?...) -> Date? {
        return result(for: query, fallback: nil, sel: { $0.dateFor(columnIndex: $1)}, arguments)
    }
}
