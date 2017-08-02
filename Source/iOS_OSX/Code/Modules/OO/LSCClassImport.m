//
//  LSCObjectProxy.m
//  LuaScriptCore
//
//  Created by 冯鸿杰 on 17/3/20.
//  Copyright © 2017年 vimfung. All rights reserved.
//

#import "LSCClassImport.h"
#import "LSCContext_Private.h"
#import "LSCValue_Private.h"
#import "LSCTypeDefinied.h"
#import "LSCPointer.h"
#import "LSCTuple.h"
#import "LSCManagedObjectProtocol.h"
#import "LSCObjectClass.h"
#import <objc/runtime.h>

/**
 包含类型列表
 */
static NSMutableDictionary *_includesClasses = nil;

/**
 实例引用表名称
 */
static NSString *const ProxyTableName = @"_import_classes_";

@implementation LSCClassImport

+ (NSString *)version
{
    return @"1.0.0";
}

+ (NSString *)moduleName
{
    return @"ClassImport";
}

+ (void)_regModule:(Class)module context:(LSCContext *)context
{
    //注册一个ObjectProxy的全局方法，用于导出原生类型
    lua_State *state = context.mainSession.state;
    
    //关联更新索引处理
    lua_pushlightuserdata(state, (__bridge void *)context);
    lua_pushcclosure(state, setupProxyHandler, 1);
    lua_setglobal(state, "ClassImport");
}

+ (void)setInculdesClasses:(NSArray<Class> *)classes withContext:(LSCContext *)context
{
    if (!_includesClasses)
    {
        _includesClasses = [NSMutableDictionary dictionary];
    }
    
    if (classes)
    {
        [_includesClasses setObject:classes forKey:[context description]];
    }
    else
    {
        [_includesClasses removeObjectForKey:[context description]];
    }
    
}

#pragma mark - Private


/**
 导出类型

 @param clsName 类型名称
 @param session 会话
 @return 返回值数量
 */
+ (int)_exportsClassWithName:(NSString *)clsName session:(LSCSession *)session
{
    lua_State *state = session.state;
    Class cls = NSClassFromString(clsName);
    
    //判断是否在导出类中
    NSArray *classes = _includesClasses[[session.context description]];
    if (![classes containsObject:cls])
    {
        //非导出类，直接返回
        NSLog(@"No permission to import the `%@` class, please call the setInculdesClasses method to set the class to the includes class list", clsName);
        return 0;
    }
    
    //判断是否为LSCObjectClass的子类
    if ([cls isSubclassOfClass:[LSCObjectClass class]])
    {
        //注册类型模块
        [session.context registerModuleWithClass:cls];
        
        //返回模块类
        NSString *moduleName = [cls moduleName];
        lua_getglobal(state, moduleName.UTF8String);
        return 1;
    }
    
    //先判断_G下是否存在对象代理表
    lua_getglobal(state, "_G");
    if (lua_type(state, -1) == LUA_TTABLE)
    {
        lua_getfield(state, -1, ProxyTableName.UTF8String);
        if (lua_type(state, -1) == LUA_TNIL)
        {
            //弹出nil
            lua_pop(state, 1);
            
            //创建对象代理表
            lua_newtable(state);
            
            lua_pushvalue(state, -1);
            lua_setfield(state, -3, ProxyTableName.UTF8String);
        }
        
        //查找是否存在此类型的代理
        lua_getfield(state, -1, clsName.UTF8String);
        if (lua_type(state, -1) == LUA_TNIL)
        {
            //弹出nil
            lua_pop(state, 1);
            
            //导出代理类型
            LSCUserdataRef userdataRef = lua_newuserdata(state, sizeof(LSCUserdataRef));
            userdataRef -> value = (void *)CFBridgingRetain(cls);

            //建立代理类元表
            lua_newtable(state);
            
            lua_pushvalue(state, -1);
            lua_setfield(state, -2, "__index");
            
            lua_pushlightuserdata(state, (__bridge void *)session.context);
            lua_pushcclosure(state, objectDestroyHandler, 1);
            lua_setfield(state, -2, "__gc");
            
            //添加创建对象方法
            lua_pushlightuserdata(state, (__bridge void *)session.context);
            lua_pushlightuserdata(state, (__bridge void *)cls);
            lua_pushcclosure(state, objectCreateHandler, 2);
            lua_setfield(state, -2, "create");
            
            //导出类方法
            [self _exportAllClassMethod:cls exportsClass:cls session:session filterMethodNames:nil];
            
            //关联元表
            lua_setmetatable(state, -2);
            
            //---------创建实例对象元表---------------
            lua_newtable(state);
            
            lua_pushvalue(state, -1);
            lua_setfield(state, -2, "__index");
            
            lua_pushlightuserdata(state, (__bridge void *)session.context);
            lua_pushcclosure(state, objectDestroyHandler, 1);
            lua_setfield(state, -2, "__gc");
            
            //导出实例方法
            [self _exportAllInstanceMethod:cls
                              exportsClass:cls
                                   session:session
                         filterMethodNames:nil];

            lua_setfield(state, -3, [NSString stringWithFormat:@"%@_prototype", clsName].UTF8String);
            
            lua_pushvalue(state, -1);
            lua_setfield(state, -3, clsName.UTF8String);
        }
        
        //移除代理表
        lua_remove(state, -2);
        //移除_G
        lua_remove(state, -2);
        
        return 1;
    }
    
    lua_pop(state, 1);
    
    return 0;
}

/**
 导出所有实例方法

 @param thiz 当前类型
 @param exportsClass 正在导出类型，该类型可以为当前类型，也可以是其父类
 @param session 会话
 @param filterMethodNames 过滤的方法名称列表
 */
+ (void)_exportAllInstanceMethod:(Class)thiz
                    exportsClass:(Class)exportsClass
                         session:(LSCSession *)session
               filterMethodNames:(NSArray<NSString *> *)filterMethodNames
{
    [self _exportInstanceMethod:thiz
                   exportsClass:exportsClass
                        session:session
              filterMethodNames:filterMethodNames];
    
    if (exportsClass != [NSObject class])
    {
        //如果不是NSObject，则获取其父类继续进行方法导出
        [self _exportAllInstanceMethod:thiz
                          exportsClass:class_getSuperclass(exportsClass)
                               session:session
                     filterMethodNames:filterMethodNames];
    }
}


/**
 导出实例方法

 @param thiz 当前类型
 @param exportsClass 正在导出类型，该类型可以为当前类型，也可以是其父类
 @param session 会话
 @param filterMethodNames 过滤的方法名称列表
 */
+ (void)_exportInstanceMethod:(Class)thiz
                 exportsClass:(Class)exportsClass
                      session:(LSCSession *)session
            filterMethodNames:(NSArray<NSString *> *)filterMethodNames
{
    lua_State *state = session.state;
    
    //解析方法
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(exportsClass, &methodCount);
    for (const Method *m = methods; m < methods + methodCount; m ++)
    {
        SEL selector = method_getName(*m);
        
        NSString *methodName = NSStringFromSelector(selector);
        if (![methodName hasPrefix:@"_"]
            && ![methodName hasPrefix:@"."]
            && ![methodName hasPrefix:@"init"]
            && ![filterMethodNames containsObject:methodName])
        {
            NSString *luaMethodName = [self _getLuaMethodNameWithName:methodName];
            
            //判断是否已导出
            BOOL hasExists = NO;
            lua_getfield(state, -1, [luaMethodName UTF8String]);
            if (!lua_isnil(state, -1))
            {
                hasExists = YES;
            }
            lua_pop(state, 1);
            
            if (!hasExists)
            {
                lua_pushlightuserdata(state, (__bridge void *)session.context);
                lua_pushlightuserdata(state, (__bridge void *)thiz);
                lua_pushstring(state, [methodName UTF8String]);
                lua_pushcclosure(state, instanceMethodRouteHandler, 3);
                
                lua_setfield(state, -2, [luaMethodName UTF8String]);
            }
        }
    }
    free(methods);
}

/**
 导出所有类方法

 @param thiz 当前类型
 @param exportsClass 正在导出类型，该类型可以为当前类型，也可以是其父类
 @param session 会话
 @param filterMethodNames 过滤的方法名称列表
 */
+ (void)_exportAllClassMethod:(Class)thiz
                 exportsClass:(Class)exportsClass
                      session:(LSCSession *)session
            filterMethodNames:(NSArray<NSString *> *)filterMethodNames
{
    [self _exportClassMethod:thiz
                exportsClass:exportsClass
                     session:session
           filterMethodNames:filterMethodNames];
    
    if (exportsClass != [NSObject class])
    {
        //如果不是NSObject，则获取其父类继续进行方法导出
        [self _exportAllClassMethod:thiz
                       exportsClass:class_getSuperclass(exportsClass)
                            session:session
                  filterMethodNames:filterMethodNames];
    }
}


/**
 导出类方法

 @param thiz 当前类型
 @param exportsClass 正在导出类型，该类型可以为当前类型，也可以是其父类
 @param session 会话
 @param filterMethodNames 过滤的方法名称列表
 */
+ (void)_exportClassMethod:(Class)thiz
              exportsClass:(Class)exportsClass
                   session:(LSCSession *)session
         filterMethodNames:(NSArray<NSString *> *)filterMethodNames
{
    lua_State *state = session.state;
    
    Class metaClass = objc_getMetaClass(NSStringFromClass(exportsClass).UTF8String);
    
    //解析方法
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(metaClass, &methodCount);
    for (const Method *m = methods; m < methods + methodCount; m ++)
    {
        SEL selector = method_getName(*m);
        
        NSString *methodName = NSStringFromSelector(selector);
        if (![methodName hasPrefix:@"_"]
            && ![methodName hasPrefix:@"."]
            && ![filterMethodNames containsObject:methodName])
        {
            NSString *luaMethodName = [self _getLuaMethodNameWithName:methodName];

            //判断是否已导出
            BOOL hasExists = NO;
            lua_getfield(state, -1, [luaMethodName UTF8String]);
            if (!lua_isnil(state, -1))
            {
                hasExists = YES;
            }
            lua_pop(state, 1);

            if (!hasExists)
            {
                lua_pushlightuserdata(state, (__bridge void *)session.context);
                lua_pushlightuserdata(state, (__bridge void *)thiz);
                lua_pushstring(state, [methodName UTF8String]);
                lua_pushcclosure(state, classMethodRouteHandler, 3);
                
                lua_setfield(state, -2, [luaMethodName UTF8String]);
            }
        }
    }
    free(methods);
}


/**
 获取Lua方法名称

 @param name 方法名称
 @return Lua的方法名称
 */
+ (NSString *)_getLuaMethodNameWithName:(NSString *)name
{
    NSString *luaName = name;
    
    NSRange range = [luaName rangeOfString:@":"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    range = [luaName rangeOfString:@"With"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    range = [luaName rangeOfString:@"At"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    range = [luaName rangeOfString:@"By"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    return luaName;
}


/**
 调用方法

 @param target 目标对象
 @param targetType 目标类型，0 类型， 1 实例
 @param selector 方法
 @param cls 类型
 @param session 会话
 @param arguments 参数列表
 @return 返回值数量
 */
+ (int)_invokeMethodWithTarget:(id)target
                    targetType:(int)targetType
                      selector:(SEL)selector
                           cls:(Class)cls
                       session:(LSCSession *)session
                     arguments:(NSArray *)arguments
{
    int retCount = 0;
    
    //修复float类型在Invocation中会丢失问题，需要定义该结构体来提供给带float参数的方法。同时返回值处理也一样。
    typedef struct {float f;} LSCFloatStruct;

    NSMethodSignature *sign = nil;
    Method m = NULL;
    switch (targetType)
    {
        case 0:
            sign = [cls methodSignatureForSelector:selector];
            m = class_getClassMethod(cls, selector);
            break;
        case 1:
            sign = [cls instanceMethodSignatureForSelector:selector];
            m = class_getInstanceMethod(cls, selector);
            break;
        default:
            break;
    }
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sign];
    [invocation setTarget:target];
    [invocation setSelector:selector];
    [invocation retainArguments];
    
    for (int i = 2; i < method_getNumberOfArguments(m); i++)
    {
        char *argType = method_copyArgumentType(m, i);
        
        int paramIndex = i;
        if (targetType == 0)
        {
            //类方法参数索引从1开始
            paramIndex -= 1;
        }
        
        LSCValue *value = nil;
        if (paramIndex - 1 < arguments.count)
        {
            value = arguments[paramIndex - 1];
        }
        else
        {
            value = [LSCValue nilValue];
        }
        
        if (strcmp(argType, @encode(float)) == 0)
        {
            //浮点型数据
            LSCFloatStruct floatValue = {[value toDouble]};
            [invocation setArgument:&floatValue atIndex:i];
        }
        else if (strcmp(argType, @encode(double)) == 0)
        {
            //双精度浮点型
            double doubleValue = [value toDouble];
            [invocation setArgument:&doubleValue atIndex:i];
        }
        else if (strcmp(argType, @encode(int)) == 0
                 || strcmp(argType, @encode(unsigned int)) == 0
                 || strcmp(argType, @encode(long)) == 0
                 || strcmp(argType, @encode(unsigned long)) == 0
                 || strcmp(argType, @encode(short)) == 0
                 || strcmp(argType, @encode(unsigned short)) == 0
                 || strcmp(argType, @encode(char)) == 0
                 || strcmp(argType, @encode(unsigned char)) == 0)
        {
            //整型
            NSInteger intValue = [value toDouble];
            [invocation setArgument:&intValue atIndex:i];
        }
        else if (strcmp(argType, @encode(BOOL)) == 0)
        {
            //布尔类型
            BOOL boolValue = [value toBoolean];
            [invocation setArgument:&boolValue atIndex:i];
        }
        else if (strcmp(argType, @encode(id)) == 0)
        {
            //对象类型
            id obj = [value toObject];
            [invocation setArgument:&obj atIndex:i];
        }
        
        free(argType);
    }
    
    [invocation invoke];
    
    char *returnType = method_copyReturnType(m);
    LSCValue *retValue = nil;
    
    if (strcmp(returnType, @encode(id)) == 0)
    {
        //返回值为对象
        id __unsafe_unretained retObj = nil;
        [invocation getReturnValue:&retObj];
        
        retValue = [LSCValue objectValue:retObj];
    }
    else if (strcmp(returnType, @encode(int)) == 0
             || strcmp(returnType, @encode(unsigned int)) == 0
             || strcmp(returnType, @encode(long)) == 0
             || strcmp(returnType, @encode(unsigned long)) == 0
             || strcmp(returnType, @encode(short)) == 0
             || strcmp(returnType, @encode(unsigned short)) == 0
             || strcmp(returnType, @encode(char)) == 0
             || strcmp(returnType, @encode(unsigned char)) == 0)
    {
        // i 整型
        // I 无符号整型
        // q 长整型
        // Q 无符号长整型
        // S 无符号短整型
        // c 字符型
        // C 无符号字符型
        
        NSInteger intValue = 0;
        [invocation getReturnValue:&intValue];
        retValue = [LSCValue integerValue:intValue];
    }
    else if (strcmp(returnType, @encode(float)) == 0)
    {
        // f 浮点型，需要将值保存到floatStruct结构中传入给方法，否则会导致数据丢失
        LSCFloatStruct floatStruct = {0};
        [invocation getReturnValue:&floatStruct];
        retValue = [LSCValue numberValue:@(floatStruct.f)];
    }
    else if (strcmp(returnType, @encode(double)) == 0)
    {
        // d 双精度浮点型
        double doubleValue = 0.0;
        [invocation getReturnValue:&doubleValue];
        retValue = [LSCValue numberValue:@(doubleValue)];
    }
    else if (strcmp(returnType, @encode(BOOL)) == 0)
    {
        //B 布尔类型
        BOOL boolValue = NO;
        [invocation getReturnValue:&boolValue];
        retValue = [LSCValue booleanValue:boolValue];
    }
    else
    {
        //结构体和其他类型暂时认为和v一样无返回值
        retValue = nil;
    }
    free(returnType);
    
    if (retValue)
    {
        retCount = [session setReturnValue:retValue];
    }
    
    return retCount;
}

#pragma mark - Lua Function Handler

/**
 *  对象更新索引处理
 *
 *  @param state 状态机
 *
 *  @return 返回值数量
 */
static int setupProxyHandler (lua_State *state)
{
    LSCContext *context = (__bridge LSCContext *)lua_topointer(state, lua_upvalueindex(1));
    LSCSession *session = [context makeSessionWithState:state];
    NSArray *arguments = [session parseArguments];
    
    if (arguments.count > 0)
    {
        //获取第一个参数
        LSCValue *clsName = arguments[0];
        if (clsName.valueType == LSCValueTypeString)
        {
            return [LSCClassImport _exportsClassWithName:[clsName toString]
                                                 session:session];
        }
    }
    
    return 0;
}

/**
 类方法路由处理器

 @param state 状态机
 
 @return 返回值数量
 */
static int classMethodRouteHandler(lua_State *state)
{
    int retCount = 0;
    
    LSCContext *context = (__bridge LSCContext *)lua_topointer(state, lua_upvalueindex(1));
    LSCSession *session = [context makeSessionWithState:state];
    
    Class moduleClass = (__bridge Class)lua_topointer(state, lua_upvalueindex(2));
    NSString *methodName = [NSString stringWithUTF8String:lua_tostring(state, lua_upvalueindex(3))];
    SEL selector = NSSelectorFromString(methodName);
    
    retCount = [LSCClassImport _invokeMethodWithTarget:moduleClass
                                            targetType:0
                                              selector:selector
                                                   cls:moduleClass
                                               session:session
                                             arguments:[session parseArguments]];
    
    return retCount;
}

/**
 实例方法路由处理

 @param state 状态机
 @return 返回值数量
 */
static int instanceMethodRouteHandler(lua_State *state)
{
    int retCount = 0;
    
    LSCContext *context = (__bridge LSCContext *)lua_topointer(state, lua_upvalueindex(1));
    Class moduleClass = (__bridge Class)lua_topointer(state, lua_upvalueindex(2));
    NSString *methodName = [NSString stringWithUTF8String:lua_tostring(state, lua_upvalueindex(3))];
    SEL selector = NSSelectorFromString(methodName);
    
    if (lua_type(state, 1) != LUA_TUSERDATA)
    {
        NSString *errMsg = [NSString stringWithFormat:@"call %@ method error : missing self parameter, please call by instance:methodName(param)", methodName];
        [context raiseExceptionWithMessage:errMsg];
        return retCount;
    }
    
    LSCSession *session = [context makeSessionWithState:state];
    NSArray *arguments = [session parseArguments];
    id instance = [arguments[0] toObject];
    
    //获取类实例对象
    if (instance)
    {
        retCount = [LSCClassImport _invokeMethodWithTarget:instance
                                                targetType:1
                                                  selector:selector
                                                       cls:moduleClass
                                                   session:session
                                                 arguments:arguments];
    }
    
    return retCount;
}

/**
 *  创建对象时处理
 *
 *  @param state 状态机
 *
 *  @return 参数数量
 */
static int objectCreateHandler (lua_State *state)
{
    LSCContext *context = (__bridge LSCContext *)lua_topointer(state, lua_upvalueindex(1));
    LSCSession *session = [context makeSessionWithState:state];
    
    Class cls = (__bridge Class)lua_topointer(state, lua_upvalueindex(2));
    NSString *clsName = NSStringFromClass(cls);
    
    //创建对象
    id instance = [[cls alloc] init];
    
    //先为实例对象在lua中创建内存
    LSCUserdataRef ref = (LSCUserdataRef)lua_newuserdata(state, sizeof(LSCUserdataRef));
    //创建本地实例对象，赋予lua的内存块并进行保留引用
    ref -> value = (void *)CFBridgingRetain(instance);
    
    //获取实例代理类型
    lua_getglobal(state, "_G");
    if (lua_type(state, -1) == LUA_TTABLE)
    {
        lua_getfield(state, -1, ProxyTableName.UTF8String);
        if (lua_type(state, -1) != LUA_TNIL)
        {
            //查找是否存在此类型的代理
            NSString *prototypeClsName = [NSString stringWithFormat:@"%@_prototype", clsName];
            lua_getfield(state, -1, prototypeClsName.UTF8String);
            if (lua_istable(state, -1))
            {
                lua_setmetatable(state, -4);
            }
            else
            {
                lua_pop(state, 1);
            }
        }
        
        lua_pop(state, 1);
        
    }
    
    lua_pop(state, 1);
    
    session = nil;
    
    return 1;
}

/**
 *  对象销毁处理
 *
 *  @param state 状态机
 *
 *  @return 参数数量
 */
static int objectDestroyHandler (lua_State *state)
{
    LSCContext *context = (__bridge LSCContext *)lua_topointer(state, lua_upvalueindex(1));
    LSCSession *session = [context makeSessionWithState:state];
    
    if (lua_gettop(state) > 0 && lua_isuserdata(state, 1))
    {
        //如果为userdata类型，则进行释放
        LSCUserdataRef ref = (LSCUserdataRef)lua_touserdata(state, 1);
        
        //释放内存
        CFBridgingRelease(ref -> value);
    }
    
    session = nil;
    
    return 0;
}

@end

#pragma mark - NSObject Category

@interface NSObject (ClassImport) <LSCManagedObjectProtocol>

@end

@implementation NSObject (ClassImport)

#pragma mark - LSCManagedObjectProtocol

- (NSString *)linkId
{
    return [NSString stringWithFormat:@"%p", self];
}

- (BOOL)pushWithContext:(LSCContext *)context
{
    lua_State *state = context.currentSession.state;
    
    NSString *clsName = NSStringFromClass([self class]);
    
    //查找类型是否为导出对象
    //获取实例代理类型
    lua_getglobal(state, "_G");
    if (lua_type(state, -1) == LUA_TTABLE)
    {
        lua_getfield(state, -1, ProxyTableName.UTF8String);
        if (lua_type(state, -1) != LUA_TNIL)
        {
            //查找是否存在此类型的代理
            NSString *prototypeClsName = [NSString stringWithFormat:@"%@_prototype", clsName];
            lua_getfield(state, -1, prototypeClsName.UTF8String);
            if (lua_istable(state, -1))
            {
                LSCUserdataRef ref = (LSCUserdataRef)lua_newuserdata(state, sizeof(LSCUserdataRef));
                //讲本地对象赋予lua的内存块并进行保留引用
                ref -> value = (void *)CFBridgingRetain(self);
                
                lua_pushvalue(state, -2);
                lua_setmetatable(state, -2);
                
                lua_remove(state, -2);  //移除代理实例元表
                lua_remove(state, -2);  //移除代理表
                lua_remove(state, -2);  //移除_G
                
                return YES;
            }

            lua_pop(state, 1);
        }
        
        lua_pop(state, 1);
    }
    
    lua_pop(state, 1);
    
    return NO;
}

@end
