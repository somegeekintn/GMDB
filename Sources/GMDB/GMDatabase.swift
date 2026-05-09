//
//  GMDatabase.swift
//  GMDB
//
//  Based on FMDB by August Mueller
//  Ported to Swift by Casey Fleser on 8/13/25.
//

import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public class GMDatabase {
    private var db: OpaquePointer?
    public private(set) var databasePath: String?
    private var openResultSets = Set<GMResultSet>()
    private var openFunctions = [SQLFunctionBox]()
    private var cachedStatements: [String: Set<GMStatement>] = [:]
    public private(set) var dateFormat: DateFormatter?

    public private(set) var isOpen = false
    public private(set) var isExecutingStatement = false
    public private(set) var isInTransaction = false
    private var crashOnErrors = false
    public private(set) var shouldCacheStatements = false
    public private(set) var maxBusyRetryTimeInterval: TimeInterval
    private var startBusyRetryTime: TimeInterval

    public var logsErrors = true
    public var traceExecution = false

    public static var GMDBUserVersion: String { "0.1.1" }
    public static var sqliteLibVersion: String { String(cString: sqlite3_libversion()) }
    public static var isSQLiteThreadSafe: Bool { sqlite3_threadsafe() != 0 }

    public var databaseURL: URL? { databasePath.flatMap { URL(filePath: $0) } }
    public var sqliteHandle: OpaquePointer? { db }
    public var hasOpenResultSets: Bool { !openResultSets.isEmpty }
    public var hasDateFormatter: Bool { dateFormat != nil }
    public var lastErrorMessage: String { String(cString: sqlite3_errmsg(db)) }
    public var hadError: Bool { (SQLITE_ERROR...SQLITE_WARNING).contains(lastErrorCode) }
    public var lastErrorCode: Int32 { sqlite3_errcode(db) }
    public var lastExtendedErrorCode: Int32 { sqlite3_extended_errcode(db) }
    public var lastError: GMDBError { errorWith(message: lastErrorMessage) }
    public var inTransaction: Bool { isInTransaction }
    public var unsafeSelfPointer: UnsafeMutableRawPointer { unsafeBitCast(self, to: UnsafeMutableRawPointer.self) }

    public var sqlitePath: String {
        guard let databasePath = databasePath as? NSString else { return ":memory:" }

        return databasePath.length == 0 ? "" : databasePath as String
    }

    public var databaseExists: Bool {
        guard !isOpen else { return true }

        gmdbLog.warning("The GMDatabase \(String(describing: self)) is not open")

#if !NS_BLOCK_ASSERTIONS
        if crashOnErrors {
            abort()
        }
#endif

        return false
    }

    public static func databaseWithPath(_ path: String) -> GMDatabase {
        GMDatabase(path: path)
    }

    public static func databaseWithURL(_ url: URL) -> GMDatabase {
        GMDatabase(url: url)
    }

    public convenience init() {
        self.init(path: nil)
    }

    public convenience init(url: URL) {
        self.init(path: url.path)
    }

    public init(path: String?) {
        assert(sqlite3_threadsafe() != 0); // whoa there big boy- gotta make sure sqlite it happy with what we're going to do.

        self.db = nil
        self.databasePath = path
        self.maxBusyRetryTimeInterval = 2
        self.startBusyRetryTime = 0
    }

    public func limit(for type: Int32, value newLimit: Int32) -> Int32 {
        return sqlite3_limit(db, type, newLimit)
    }

    @discardableResult
    public func open() -> Bool {
        guard !isOpen else { return true }

        isOpen = true

        // if we previously tried to open and it failed, make sure to close it before we try again
        if db != nil {
            close()
        }

        // now open database
        let err = sqlite3_open(sqlitePath, &db)

        if err != SQLITE_OK {
            gmdbLog.error("error opening!: \(err)")
            return false
        }

        if (maxBusyRetryTimeInterval > 0.0) {
            // set the handler
            setMaxBusyRetryTimeInterval(maxBusyRetryTimeInterval)
        }

        return true
    }

    @discardableResult
    public func openWith(flags: Int32, vfs vfsName: String? = nil) -> Bool {
        // Note: assumes SQLITE_VERSION_NUMBER >= 3005000
        guard !isOpen else { return true }

        // if we previously tried to open and it failed, make sure to close it before we try again
        if db != nil {
            close()
        }

        // now open database
        let err = sqlite3_open_v2(sqlitePath, &db, flags, (vfsName as NSString?)?.utf8String)

        if err != SQLITE_OK {
            gmdbLog.error("error opening!: \(err)")
            return false
        }

        if maxBusyRetryTimeInterval > 0.0 {
            setMaxBusyRetryTimeInterval(maxBusyRetryTimeInterval)
        }

        isOpen = true

        return true
    }

    @discardableResult
    public func close() -> Bool {
        clearCachedStatements()
        closeOpenResultSets()

        if let db {
            var retry = false
            var triedFinalizingOpenStatements = false

            repeat {
                retry = false

                let rc = sqlite3_close(db)
                switch rc {
                case SQLITE_BUSY, SQLITE_LOCKED:
                    if !triedFinalizingOpenStatements {
                        triedFinalizingOpenStatements = true

                        while let stmt = sqlite3_next_stmt(db, nil) {
                            gmdbLog.notice("Closing leaked statement")
                            sqlite3_finalize(stmt)
                            retry = true
                        }
                    }
                case SQLITE_OK:
                    break
                default:
                    gmdbLog.error("error opening!: \(rc)")
                }
            } while (retry)

            self.db = nil
            isOpen = false
        }

        return true
    }

    func databaseBusyHandler(count: Int32) -> Int32 {
        if count == 0 {
            startBusyRetryTime = Date.timeIntervalSinceReferenceDate
            return 1
        }
        else {
            let delta = Date.timeIntervalSinceReferenceDate - startBusyRetryTime

            if delta < maxBusyRetryTimeInterval {
                let msRequestedSleep = Int32(arc4random_uniform(50) + 50)
                let msActualSleep = sqlite3_sleep(msRequestedSleep)

                if msActualSleep != msRequestedSleep {
                    gmdbLog.warning("WARNING: Requested sleep of \(msRequestedSleep) milliseconds, but SQLite returned \(msActualSleep). Maybe SQLite wasn't built with HAVE_USLEEP=1?")
                }
            }

            return 0
        }
    }

    public func setMaxBusyRetryTimeInterval(_ timeout: TimeInterval) {
        guard let db else { return }

        maxBusyRetryTimeInterval = timeout

        if timeout > 0 {
            sqlite3_busy_handler(db, { unsafeBitCast($0, to: GMDatabase.self).databaseBusyHandler(count: $1) }, unsafeSelfPointer)
        }
        else {
            // turn it off otherwise
            sqlite3_busy_handler(db, nil, nil)
        }
    }

    public func closeOpenResultSets() {
        for rs in openResultSets {
            rs.parentDB = nil
            rs.close()

            openResultSets.remove(rs)
        }
    }

    func resultSetDidClose(_ resultSet: GMResultSet) {
        openResultSets.remove(resultSet)
    }

    public func clearCachedStatements() {
        for statements in cachedStatements.values {
            for statement in statements {
                statement.close()
            }
        }
        cachedStatements.removeAll()
    }

    func cachedStatementFor(query: String) -> GMStatement? {
        let statements = cachedStatements[query]

        return statements?.first { !$0.inUse }
    }

    func setCachedStatement(_ statement: GMStatement, forQuery query: String) {
        var statements = cachedStatements[query] ?? []

        statement.query = query
        statements.insert(statement)
        cachedStatements[query] = statements
    }

    static func storeableDateFormat(_ format: String) -> DateFormatter {
        let result = DateFormatter()
        result.dateFormat = format
        result.timeZone = TimeZone(secondsFromGMT: 0)
        result.locale = Locale(identifier: "en_US")
        return result
    }

    public func setDateFormat(_ format: DateFormatter) {
        dateFormat = format
    }

    public func stringFrom(date: Date) -> String {
        dateFormat?.string(from: date) ?? "\(date)"
    }

    public func goodConnection() -> Bool {
        // SQLCIPHER_CRYPTO support? Only appears in podspec
        guard isOpen else { return false }
        guard let rs = executeQuery("select name from sqlite_master where type='table'") else { return false }

        rs.close()

        return true
    }

    public func warnInUse() {
        gmdbLog.warning("The GMDatabase \(String(describing: self)) is currently in use.")

#if !NS_BLOCK_ASSERTIONS
        if crashOnErrors {
            abort()
        }
#endif
    }

    func errorWith(message: String) -> GMDBError {
        .sql(sqlite3_errcode(db), message)
    }

    public func lastInsertRowId() -> sqlite_int64 {
        guard !isExecutingStatement else { warnInUse(); return 0 }
        let result: sqlite_int64

        isExecutingStatement = true
        result = sqlite3_last_insert_rowid(db)
        isExecutingStatement = false

        return result
    }

    public func changes() -> Int32 {
        guard !isExecutingStatement else { warnInUse(); return 0 }
        let result: Int32

        isExecutingStatement = true
        result = sqlite3_changes(db)
        isExecutingStatement = false

        return result
    }

    public func bindObject(obj: Any?, toColumn idx: Int32, inStatement pStmt: OpaquePointer) -> Int32 {
        guard let obj else { return sqlite3_bind_null(pStmt, idx) }

        // FIXME - someday check the return codes on these binds.
        switch obj {
        case let val as Data:
            var data = (val as NSData)

            if data.length == 0 {  // If the length of the NSData object is 0, this property (bytes) returns nil.
                data = ("".data(using: .utf8) as NSData?) ?? data
            }

            return sqlite3_bind_blob(pStmt, idx, data.bytes, Int32(data.length), SQLITE_TRANSIENT)

        case let val as Date:
            if hasDateFormatter {
                let formattedDate = stringFrom(date: val)

                return sqlite3_bind_text(pStmt, idx, (formattedDate as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            else {
                return sqlite3_bind_double(pStmt, idx, val.timeIntervalSince1970)
            }

        case let val as Int8:
            return sqlite3_bind_int(pStmt, idx, Int32(val))
        case let val as UInt8:
            return sqlite3_bind_int(pStmt, idx, Int32(bitPattern: UInt32(val)))
        case let val as Int16:
            return sqlite3_bind_int(pStmt, idx, Int32(val))
        case let val as UInt16:
            return sqlite3_bind_int(pStmt, idx, Int32(bitPattern: UInt32(val)))
        case let val as Int32:
            return sqlite3_bind_int(pStmt, idx, Int32(val))
        case let val as UInt32:
            return sqlite3_bind_int64(pStmt, idx, Int64(bitPattern: UInt64(val)))
        case let val as Int64:
            return sqlite3_bind_int64(pStmt, idx, val)
        case let val as UInt64:
            return sqlite3_bind_int64(pStmt, idx, Int64(bitPattern: val))
        case let val as Int:
            return sqlite3_bind_int64(pStmt, idx, Int64(val))
        case let val as UInt:
            return sqlite3_bind_int64(pStmt, idx, Int64(bitPattern: UInt64(val)))
        case let val as Float:
            return sqlite3_bind_double(pStmt, idx, Double(val))
        case let val as Double:
            return sqlite3_bind_double(pStmt, idx, val)
        case let val as Bool:
            return sqlite3_bind_int(pStmt, idx, val ? 1 : 0)
        case is NSNull:
            return sqlite3_bind_null(pStmt, idx)
        default:
            return sqlite3_bind_text(pStmt, idx, ("\(obj)" as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
    }

    // - (void)extractSQL:(NSString *)sql argumentsList:(va_list)args … - Unsupported

    public func executeQuery(_ sql: String, dictionary arguments: [String: Any?]) -> GMResultSet? {
        executeQuery(sql, arguments: .dictionary(arguments), shouldBind: true)
    }

    public func executeQuery(_ sql: String, array arguments: [Any?]) -> GMResultSet? {
        executeQuery(sql, arguments: .array(arguments), shouldBind: true)
    }

    public func executeQuery(_ sql: String, _ arguments: Any?...) -> GMResultSet? {
        executeQuery(sql, arguments: .array(arguments), shouldBind: true)
    }

    public func executeQuery(_ sql: String, arguments: Arguments, shouldBind: Bool) -> GMResultSet? {
        guard databaseExists else { return nil }
        guard !isExecutingStatement else { warnInUse(); return nil }
        var pStmt: OpaquePointer? = nil
        var cachedStatement: GMStatement?
        let statement: GMStatement
        let rs: GMResultSet

        isExecutingStatement = true

        if traceExecution{
            gmdbLog.info("\(String(describing: self)) executeQuery: \(sql)")
        }

        if shouldCacheStatements {
            cachedStatement = cachedStatementFor(query: sql)
            pStmt = cachedStatement?.statement
            cachedStatement?.reset()
        }

        if pStmt == nil {
            let rc = sqlite3_prepare_v2(db, (sql as NSString).utf8String, -1, &pStmt, nil);

            if rc != SQLITE_OK {
                if logsErrors || crashOnErrors {
                    gmdbLog.error("DB Error: \(self.lastErrorCode) \"\(self.lastErrorMessage)\"")
                }

                if logsErrors {
                    gmdbLog.error("DB Query: \(sql)")
                    gmdbLog.error("DB Path: \(self.databasePath ?? "N/A")")
                }

                if crashOnErrors {
                    abort()
                }

                sqlite3_finalize(pStmt)
                pStmt = nil
                isExecutingStatement = false
                return nil
            }
        }

        if shouldBind {
            if let pStmt {
                if !bindStatement(pStmt: pStmt, arguments: arguments) {
                    return nil
                }
            }
        }

        statement = cachedStatement ?? {
            let newStatement = GMStatement(statement: pStmt)

            if shouldCacheStatements {
                setCachedStatement(newStatement, forQuery: sql)
            }
            return newStatement
        }()

        // the statement gets closed in rs's deinit or rs.close()
        // we should only autoclose if we're binding automatically when the statement is prepared
        rs = GMResultSet(parentDB: self, statement: statement, shouldAutoClose: shouldBind)
        rs.query = sql
        openResultSets.insert(rs)
        statement.useCount += 1

        isExecutingStatement = false

        return rs
    }

    public func bindStatement(pStmt: OpaquePointer, arguments: Arguments) -> Bool {
        var idx = 0
        let queryCount = sqlite3_bind_parameter_count(pStmt) // pointed out by Dominic Yu (thanks!)

        switch arguments {
        case .dictionary(let dictionary):
            for keyValue in dictionary {
                // Prefix the key with a colon.
                let parameterName = ":\(keyValue.key)"

                if traceExecution {
                    gmdbLog.info("\(parameterName) - \(String(describing: keyValue.value))")
                }

                // Get the index for the parameter name.
                let namedIdx = sqlite3_bind_parameter_index(pStmt, (parameterName as NSString).utf8String)

                if namedIdx > 0 {
                    // Standard binding from here.
                    let rc = bindObject(obj: keyValue.value, toColumn: namedIdx, inStatement: pStmt)
                    if rc != SQLITE_OK {
                        gmdbLog.error("Error: unable to bind \(rc), \(self.lastErrorMessage)")
                        sqlite3_finalize(pStmt)
                        isExecutingStatement = false
                        return false
                    }
                    // increment the binding count, so our check below works out
                    idx += 1
                }
                else {
                    gmdbLog.warning("Could not find index for \(keyValue.key)");
                }
            }
        case .array(let array):
            while idx < queryCount {
                guard idx < array.count else { break }  // We ran out of arguments
                let obj = array[idx]

                if traceExecution {
                    if let data = obj as? Data {
                        gmdbLog.info("data: \(data.count) bytes")
                    }
                    else {
                        gmdbLog.info("obj: \(String(describing: obj))")
                    }

                }

                idx += 1
                let rc = bindObject(obj: obj, toColumn: Int32(idx), inStatement: pStmt)

                if rc != SQLITE_OK {
                    gmdbLog.error("Error: unable to bind \(rc), \(self.lastErrorMessage)")
                    sqlite3_finalize(pStmt)
                    isExecutingStatement = false
                    return false
                }
            }
        }

        if idx != queryCount {
            gmdbLog.error("Error: the bind count is not correct for the # of variables (executeQuery)")
            sqlite3_finalize(pStmt);
            isExecutingStatement = false
            return false
        }

        return true;
    }

    @discardableResult
    public func executeUpdate(_ sql: String, arguments: Arguments) throws -> Bool {
        guard let rs = self.executeQuery(sql, arguments: arguments, shouldBind: true) else { throw lastError }

        return try rs.internalStep() == SQLITE_DONE
    }

    @discardableResult
    public func executeUpdate(_ sql: String, _ args: Any?...) throws -> Bool {
        try executeUpdate(sql, arguments: .array(args))
    }

    @discardableResult
    public func executeUpdate(_ sql: String, parameterArray arguments: [Any?]) throws -> Bool {
        try executeUpdate(sql, arguments: .array(arguments))
    }

    @discardableResult
    public func executeUpdate(_ sql: String, parameterDictionary arguments: [String: Any?]) throws -> Bool {
        try executeUpdate(sql, arguments: .dictionary(arguments))
    }

    // - (BOOL)executeUpdateWithFormat:(NSString*)format, - Unsupported

    @discardableResult
    public func executeUpdate(_ sql: String, withError err: inout Error?, _ args: Any?...) -> Bool {
        let result: Bool

        do {
            result = try executeUpdate(sql, args)
        }
        catch {
            err = error
            result = false
        }

        return result
    }

    public func executeStatements(_ sql: String, withResultBlock block: ExecuteStatementsCallback? = nil) -> Bool {
        var errmsg: UnsafeMutablePointer<CChar>? = nil
        let box = block.map { ExecuteStatementsCallbackBox($0) }
        let userData = box.map { Unmanaged.passUnretained($0).toOpaque() }

        let rc = sqlite3_exec(db, sql, block != nil ? { userData, columns, values, names in
            guard let userData = userData else { return SQLITE_OK }
            let box = Unmanaged<ExecuteStatementsCallbackBox>.fromOpaque(userData).takeUnretainedValue()
            var dict: [String: String] = [:]

            if let names {
                for i in 0..<Int(columns) {
                    guard let key = names[i].map({ String(cString: $0) }) else { continue }
                    guard let value = values?[i].map({ String(cString: $0) }) else { continue }

                    dict[key] = value
                }
            }

            return Int32(box.block(dict))
        } : nil, userData, &errmsg)

        if let errmsg = errmsg {
            if logsErrors {
                gmdbLog.error("Error inserting batch: \(String(cString: errmsg))")
            }
            sqlite3_free(errmsg)
        }

        return rc == SQLITE_OK
    }

    public func prepare(_ sql: String) -> GMResultSet? {
        executeQuery(sql, arguments: .array([]), shouldBind: false)
    }

    @discardableResult
    public func rollback() throws -> Bool {
        let b = try executeUpdate("rollback transaction")

        if b {
            isInTransaction = false
        }

        return b
    }

    @discardableResult
    public func commit() throws -> Bool {
        let b = try executeUpdate("commit transaction")

        if b {
            isInTransaction = false
        }

        return b
    }

    @discardableResult
    public func beginTransaction() throws -> Bool {
        let b = try executeUpdate("begin exclusive transaction")

        if b {
            isInTransaction = true
        }

        return b
    }

    @discardableResult
    public func beginDeferredTransaction() throws -> Bool {
        let b = try executeUpdate("begin deferred transaction")

        if b {
            isInTransaction = true
        }

        return b
    }

    @discardableResult
    public func beginImmediateTransaction() throws -> Bool {
        let b = try executeUpdate("begin immediate transaction")

        if b {
            isInTransaction = true
        }

        return b
    }

    @discardableResult
    public func beginExclusiveTransaction() throws -> Bool {
        let b = try executeUpdate("begin exclusive transaction")

        if b {
            isInTransaction = true
        }

        return b
    }

    public func checkpoint(checkpointMode: GMDBCheckpointMode, name: String? = nil) throws -> Bool {
        var logFrameCount: Int32 = 0
        var checkpointCount: Int32 = 0

        return try checkpoint(checkpointMode: checkpointMode, name: name, logFrameCount: &logFrameCount, checkpointCount: &checkpointCount)
    }

    @discardableResult
    public func checkpoint(checkpointMode: GMDBCheckpointMode, name: String? = nil, logFrameCount: inout Int32, checkpointCount: inout Int32) throws -> Bool {
        let err = sqlite3_wal_checkpoint_v2(db, name?.cString(using: .utf8), checkpointMode.rawValue, &logFrameCount, &checkpointCount)

        if err != SQLITE_OK {
            let error = lastError

            if logsErrors || crashOnErrors {
                gmdbLog.error("DB Error: \(self.lastErrorCode) \"\(self.lastErrorMessage)\"")
            }
            if crashOnErrors {
                abort()
            }

            throw error
        }
        else {
            return true
        }
    }

    public func setShouldCacheStatements(_ value: Bool) {
        shouldCacheStatements = value

        if !shouldCacheStatements {
            cachedStatements.removeAll()
        }
    }

    public func makeFunction(named name: String, arguments: Int32, block: @escaping SQLFunction) {
        let box = SQLFunctionBox(block)
        let opaqueBox = Unmanaged.passUnretained(box).toOpaque()

        openFunctions.append(box)

        sqlite3_create_function(db, name, arguments, SQLITE_UTF8, opaqueBox, { context, argc, argv in
            guard let opaqueBox = sqlite3_user_data(context) else { return }
            let box = Unmanaged<SQLFunctionBox>.fromOpaque(opaqueBox).takeUnretainedValue()
            let args = (0..<Int(argc)).map { argv?[$0] }

            box.block(context, argc, args)
        }, nil, nil)
    }

    public func valueType(_ value: OpaquePointer?) -> SQLiteValueType {
        return SQLiteValueType(rawValue: sqlite3_value_type(value)) ?? .null
    }

    public func valueInt(_ value: OpaquePointer?) -> Int32 {
        return sqlite3_value_int(value)
    }

    public func valueLong(_ value: OpaquePointer?) -> Int64 {
        return sqlite3_value_int64(value)
    }

    public func valueDouble(_ value: OpaquePointer?) -> Double {
        return sqlite3_value_double(value)
    }

    public func valueData(_ value: OpaquePointer?) -> Data? {
        guard let bytes = sqlite3_value_blob(value) else { return nil }
        let i8bufptr = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: Int(sqlite3_value_bytes(value)))

        return Data(i8bufptr)
    }

    public func valueString(_ value: OpaquePointer?) -> String? {
        guard let cString = sqlite3_value_text(value) else { return nil }

        return String(cString: cString)
    }

    public func resultNull(in context: OpaquePointer?) {
        sqlite3_result_null(context)
    }

    public func resultInt(_ value: Int32, in context: OpaquePointer?) {
        sqlite3_result_int(context, value)
    }

    public func resultLong(_ value: Int64, in context: OpaquePointer?) {
        sqlite3_result_int64(context, value)
    }

    public func resultDouble(_ value: Double, in context: OpaquePointer?) {
        sqlite3_result_double(context, value)
    }

    public func resultData(_ data: Data, in context: OpaquePointer?) {
        data.withUnsafeBytes { bytes in
            sqlite3_result_blob(context, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    public func resultString(_ value: String, in context: OpaquePointer?) {
        sqlite3_result_text(context, value.cString(using: .utf8), -1, SQLITE_TRANSIENT)
    }

    public func resultError(_ error: String, in context: OpaquePointer?) {
        sqlite3_result_error(context, error.cString(using: .utf8), -1)
    }

    public func resultErrorCode(_ errorCode: Int32, in context: OpaquePointer?) {
        sqlite3_result_error_code(context, errorCode)
    }

    public func resultErrorNoMemory(in context: OpaquePointer?) {
        sqlite3_result_error_nomem(context)
    }

    public func resultErrorTooBig(in context: OpaquePointer?) {
        sqlite3_result_error_toobig(context)
    }
}
