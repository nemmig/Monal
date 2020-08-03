//
//  MLSQLite.m
//  Monal
//
//  Created by Thilo Molitor on 31.07.20.
//  Copyright © 2020 Monal.im. All rights reserved.
//

#import <sqlite3.h>
#import "MLSQLite.h"

@interface MLSQLite()
{
    NSString* _dbFile;
    sqlite3* database;
}
@end

@implementation MLSQLite

+(void) initialize
{
    if(sqlite3_config(SQLITE_CONFIG_MULTITHREAD) == SQLITE_OK)
        DDLogInfo(@"sqlite initialize: Database configured ok");
    else
    {
        DDLogError(@"sqlite initialize: Database not configured ok");
        @throw [NSException exceptionWithName:@"RuntimeException" reason:@"sqlite3_config() failed" userInfo:nil];
    }
    
    sqlite3_initialize();
}

//every thread gets its own instance having its own db connection
//this allows for concurrent reads/writes
+(id) sharedInstanceForFile:(NSString*) dbFile
{
	NSMutableDictionary* threadData = [[NSThread currentThread] threadDictionary];
	if(threadData[@"_sqliteInstancesForThread"] && threadData[@"_sqliteInstancesForThread"][dbFile])
		return threadData[@"_sqliteInstancesForThread"][dbFile];
	MLSQLite* newInstance = [[self alloc] initWithFile:dbFile];
	threadData[@"_sqliteInstancesForThread"] = @{dbFile: newInstance};          //save thread-local instance
	threadData[@"_sqliteTransactionRunning"] = [NSNumber numberWithInt:0];     //init data for nested transactions
	return newInstance;
}

-(id) initWithFile:(NSString*) dbFile
{
    _dbFile = dbFile;
    DDLogVerbose(@"db path %@", _dbFile);
    if(sqlite3_open_v2([_dbFile UTF8String], &(self->database), SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    {
        DDLogInfo(@"Database opened: %@", _dbFile);
    }
    else
    {
        //database error message
        DDLogError(@"Error opening database: %@", _dbFile);
        @throw [NSException exceptionWithName:@"RuntimeException" reason:@"sqlite3_open_v2() failed" userInfo:nil];
    }

    //use WAL mode for db to speedup access using multiple threads
    [self executeNonQuery:@"pragma journal_mode=WAL;" andArguments:nil];
    [self executeNonQuery:@"pragma synchronous=NORMAL;" andArguments:nil];

    //truncate is faster than delete
    [self executeNonQuery:@"pragma truncate;" andArguments:nil];

    return self;
}

-(void) dealloc
{
    //this dealloc method will only be called if a thread gets terminated --> do some cleanup

    //invalidate sqlite statements in the thread dict (they will not be deallocated automatically because they are no objc objects)
    NSMutableDictionary* threadData = [[NSThread currentThread] threadDictionary];
    if(threadData[@"_sqliteStatementCache"])
    {
        for(NSString* query in threadData[@"_sqliteStatementCache"])
        {
            NSValue* value = threadData[@"_sqliteStatementCache"][query];
            sqlite3_finalize((sqlite3_stmt*)[value pointerValue]);
        }
    }
    
    //we don't need to dealloc any objc objects because they will be deallocated automatically

    DDLogVerbose(@"Closing database: %@", _dbFile);
    sqlite3_close(self->database);
}

#pragma mark - private sql api

-(void) invalidateStatementForQuery:(NSString*) query
{
    if(!query)
        return;

    NSMutableDictionary* threadData = [[NSThread currentThread] threadDictionary];

    //init statement cache if neccessary
    if(!threadData[@"_sqliteStatementCache"])
        threadData[@"_sqliteStatementCache"] = [[NSMutableDictionary alloc] init];

    //finalize sqlite statement
    if(threadData[@"_sqliteStatementCache"][query])
        sqlite3_finalize((sqlite3_stmt*)[threadData[@"_sqliteStatementCache"][query] pointerValue]);

    //invalidate cache entry for this query
    [threadData[@"_sqliteStatementCache"] removeObjectForKey:query];
}

-(sqlite3_stmt*) prepareQuery:(NSString*) query withArgs:(NSArray*) args
{
    NSMutableDictionary* threadData = [[NSThread currentThread] threadDictionary];
    sqlite3_stmt* statement;

    //init statement cache if neccessary
    if(!threadData[@"_sqliteStatementCache"])
        threadData[@"_sqliteStatementCache"] = [[NSMutableDictionary alloc] init];

    //check if the statement was already prepared and stored in cache to speed up things
    if(threadData[@"_sqliteStatementCache"][query])
        statement = (sqlite3_stmt*)[threadData[@"_sqliteStatementCache"][query] pointerValue];
    else
    {
        if(sqlite3_prepare_v2(self->database, [query cStringUsingEncoding:NSUTF8StringEncoding], -1, &statement, NULL) != SQLITE_OK)
        {
            DDLogError(@"sqlite prepare '%@' failed: %s", query, sqlite3_errmsg(self->database));
            return NULL;
        }
        threadData[@"_sqliteStatementCache"][query] = [NSValue valueWithPointer:statement];
    }
    
    //bind args to statement
    sqlite3_reset(statement);
    [args enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if([obj isKindOfClass:[NSNumber class]])
        {
            NSNumber *number = (NSNumber *) obj;
            if(sqlite3_bind_double(statement, (signed)idx+1, [number doubleValue]) != SQLITE_OK)
                DDLogError(@"number bind error");
        }
        else if([obj isKindOfClass:[NSString class]])
        {
            NSString *text = (NSString *) obj;
            if(sqlite3_bind_text(statement, (signed)idx+1, [text cStringUsingEncoding:NSUTF8StringEncoding], -1, SQLITE_TRANSIENT) != SQLITE_OK)
                DDLogError(@"string bind error");
        }
        else if([obj isKindOfClass:[NSData class]])
        {
            NSData* data = (NSData *) obj;
            if(sqlite3_bind_blob(statement, (signed)idx+1, [data bytes], (int)data.length, SQLITE_TRANSIENT) != SQLITE_OK)
                DDLogError(@"blob bind error");
        }
    }];
    
    return statement;
}

-(NSObject*) getColumn:(int) column ofStatement:(sqlite3_stmt*) statement
{
    switch(sqlite3_column_type(statement, column))
    {
        //SQLITE_INTEGER, SQLITE_FLOAT, SQLITE_TEXT, SQLITE_BLOB, or SQLITE_NULL
        case(SQLITE_INTEGER):
        {
            NSNumber* returnInt = [NSNumber numberWithInt:sqlite3_column_int(statement, column)];
            return returnInt;
        }
        case(SQLITE_FLOAT):
        {
            NSNumber* returnFloat = [NSNumber numberWithDouble:sqlite3_column_double(statement, column)];
            return returnFloat;
        }
        case(SQLITE_TEXT):
        {
            NSString* returnString = [NSString stringWithUTF8String:(const char* _Nonnull) sqlite3_column_text(statement, column)];
            return returnString;
        }
        case(SQLITE_BLOB):
        {
            const char* bytes = (const char* _Nonnull) sqlite3_column_blob(statement, column);
            int size = sqlite3_column_bytes(statement, column);
            NSData* returnData = [NSData dataWithBytes:bytes length:size];
            return returnData;
        }
        case(SQLITE_NULL):
        {
            return nil;
        }
    }
    return nil;
}

-(void) throwErrorForQuery:(NSString*) query
{
    NSString* error = [NSString stringWithFormat:@"%@ --> %@", query, [NSString stringWithUTF8String:sqlite3_errmsg(self->database)]];
    @throw [NSException exceptionWithName:@"SQLite3Exception" reason:error userInfo:@{@"query": query}];
}

#pragma mark - V1 low level

-(void) beginWriteTransaction
{
	NSMutableDictionary* threadData = [[NSThread currentThread] threadDictionary];
    DDLogVerbose(@"threadData: %@", threadData);
	threadData[@"_sqliteTransactionRunning"] = [NSNumber numberWithInt:[threadData[@"_sqliteTransactionRunning"] intValue] + 1];
	if([threadData[@"_sqliteTransactionRunning"] intValue] > 1)
		return;			//begin only outermost transaction
	BOOL retval;
	do {
		retval=[self executeNonQuery:@"BEGIN IMMEDIATE TRANSACTION;" andArguments:nil];
        DDLogVerbose(@"sqlite3 transaction begin query returned: %@", retval ? @"YES" : @"NO");
		if(!retval)
			[NSThread sleepForTimeInterval:1.001f];		//wait one millisecond and retry again
	} while(!retval);
}

-(void) endWriteTransaction
{
	NSMutableDictionary* threadData = [[NSThread currentThread] threadDictionary];
	threadData[@"_sqliteTransactionRunning"] = [NSNumber numberWithInt:[threadData[@"_sqliteTransactionRunning"] intValue] - 1];
	if([threadData[@"_sqliteTransactionRunning"] intValue] == 0)
    {
		BOOL retval=[self executeNonQuery:@"COMMIT;" andArguments:nil];		//commit only outermost transaction
		DDLogVerbose(@"sqlite3 transaction end query returned: %@", retval ? @"YES" : @"NO");
    }
}

-(NSObject*) executeScalar:(NSString*) query andArguments:(NSArray*) args
{
    if(!query)
        return nil;
    
    NSObject* __block toReturn;
    sqlite3_stmt* statement = [self prepareQuery:query withArgs:args];
    if(statement != NULL)
    {
        int step;
        if((step=sqlite3_step(statement)) == SQLITE_ROW)
        {
            toReturn = [self getColumn:0 ofStatement:statement];
            while((step=sqlite3_step(statement)) == SQLITE_ROW) {}     //clear data of all other rows
        }
        if(step != SQLITE_DONE)
            [self throwErrorForQuery:query];
    }
    else
    {
        //if noting else
        DDLogVerbose(@"returning nil with out OK %@", query);
        toReturn = nil;
        [self invalidateStatementForQuery:query];
        [self throwErrorForQuery:query];
    }

    return toReturn;
}

-(NSMutableArray*) executeReader:(NSString*) query andArguments:(NSArray*) args
{
    if(!query)
        return nil;

    NSMutableArray* toReturn = [[NSMutableArray alloc] init];
    sqlite3_stmt* statement = [self prepareQuery:query withArgs:args];
    if(statement != NULL)
    {
        int step;
        while((step=sqlite3_step(statement)) == SQLITE_ROW)
        {
            NSMutableDictionary* row = [[NSMutableDictionary alloc] init];
            int counter = 0;
            while(counter < sqlite3_column_count(statement))
            {
                NSString* columnName = [NSString stringWithUTF8String:sqlite3_column_name(statement, counter)];
                NSObject* returnData = [self getColumn:counter ofStatement:statement];
                //accessing an unset key in NSDictionary will return nil (nil can not be inserted directly into the dictionary)
                if(returnData != nil)
                    [row setObject:returnData forKey:columnName];
                counter++;
            }
            [toReturn addObject:row];
        }
        if(step != SQLITE_DONE)
            [self throwErrorForQuery:query];
    }
    else
    {
        //if noting else
        DDLogVerbose(@"reader nil with sql not ok: %@", query);
        toReturn = nil;
        [self invalidateStatementForQuery:query];
        [self throwErrorForQuery:query];
    }

    return toReturn;
}

-(BOOL) executeNonQuery:(NSString*) query andArguments:(NSArray *) args
{
    if(!query)
        return NO;
    BOOL toReturn;
    sqlite3_stmt* statement = [self prepareQuery:query withArgs:args];
    if(statement != NULL)
    {
        int step;
        while((step=sqlite3_step(statement)) == SQLITE_ROW) {}     //clear data of all returned rows
        if(step == SQLITE_DONE)
            toReturn = YES;
        else
        {
            DDLogVerbose(@"sqlite3_step(%@): %d --> %@", query, step, [[NSThread currentThread] threadDictionary]);
            [self throwErrorForQuery:query];
            toReturn = NO;
        }
    }
    else
    {
        DDLogError(@"nonquery returning NO with out OK %@", query);
        toReturn = NO;
        [self invalidateStatementForQuery:query];
        [self throwErrorForQuery:query];
    }
    return toReturn;
}

#pragma mark - V2 low level

-(void) executeScalar:(NSString*) query withCompletion:(void (^)(NSObject*)) completion
{
    [self executeScalar:query andArguments:nil withCompletion:completion];
}

-(void) executeReader:(NSString*) query withCompletion:(void (^)(NSMutableArray*)) completion
{
    [self executeReader:query andArguments:nil withCompletion:completion];
}

-(void) executeNonQuery:(NSString*) query withCompletion:(void (^)(BOOL)) completion
{
    [self executeNonQuery:query andArguments:nil withCompletion:completion];
}

-(void) executeScalar:(NSString*) query andArguments:(NSArray*) args withCompletion:(void (^)(NSObject*)) completion
{
    NSObject* retval = [self executeScalar:query andArguments:args];
    if(completion)
        completion(retval);
}

-(void) executeReader:(NSString*) query andArguments:(NSArray*) args withCompletion:(void (^)(NSMutableArray*)) completion
{
    NSMutableArray* retval = [self executeReader:query andArguments:args];
    if(completion)
        completion(retval);
}

-(void) executeNonQuery:(NSString*) query andArguments:(NSArray*) args  withCompletion:(void (^)(BOOL)) completion
{
    BOOL retval = [self executeNonQuery:query andArguments:args];
    if(completion)
        completion(retval);
}

@end
