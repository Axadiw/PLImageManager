/*
 Copyright (c) 2013, Antoni Kędracki, Polidea
 All rights reserved.

 mailto: akedracki@gmail.com

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the Polidea nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY ANTONI KĘDRACKI, POLIDEA ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL ANTONI KĘDRACKI, POLIDEA BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "PLImageManager.h"
#import "PLImageCache.h"
#import "PLImageManagerLoadOperation.h"
#import "PLImageManagerOpRunner.h"

@interface PLImageManager ()

- (id)initWithProvider:(id <PLImageManagerProvider>)aProvider cache:(PLImageCache *)aCache ioOpRunner:(PLImageManagerOpRunner *)ioOpRunner downloadOpRunner:(PLImageManagerOpRunner *)downloadOpRunner sentinelOpRunner:(PLImageManagerOpRunner *)sentinelOpRunner;

@end

@interface PLImageManagerRequestToken ()

- (id)initWithKey:(NSString *)aKey;
- (void)markReady;

@property (nonatomic, copy, readwrite) void (^onCancelBlock)();

@end

@implementation PLImageManager {
    PLImageManagerOpRunner *ioQueue;
    PLImageManagerOpRunner *downloadQueue;
    PLImageManagerOpRunner *sentinelQueue;

    PLImageCache *imageCache;
    id <PLImageManagerProvider> provider;
    NSMutableDictionary *sentinelDict;
}

- (id)initWithProvider:(id <PLImageManagerProvider>)aProvider {
    return [self initWithProvider:aProvider cache:[PLImageCache new] ioOpRunner:[PLImageManagerOpRunner new] downloadOpRunner:[PLImageManagerOpRunner new] sentinelOpRunner:[PLImageManagerOpRunner new]];
}

//Note: this constructor is used by tests
- (id)initWithProvider:(id <PLImageManagerProvider>)aProvider cache:(PLImageCache *)aCache ioOpRunner:(PLImageManagerOpRunner *)aIoOpRunner downloadOpRunner:(PLImageManagerOpRunner *)aDownloadOpRunner sentinelOpRunner:(PLImageManagerOpRunner *)aSentinelOpRunner {
    self = [super init];
    if (self) {
        if (aProvider == nil) {
            @throw [NSException exceptionWithName:@"InvalidArgumentException" reason:@"A valid provider is missing" userInfo:nil];
        }

        provider = aProvider;

        ioQueue = aIoOpRunner;
        ioQueue.name = @"plimagemanager.io";
        ioQueue.maxConcurrentOperationsCount = 1;
        downloadQueue = aDownloadOpRunner;
        downloadQueue.name = @"plimagemanager.download";
        downloadQueue.maxConcurrentOperationsCount = [provider maxConcurrentDownloadsCount];
        sentinelQueue = aSentinelOpRunner;
        sentinelQueue.name = @"plimagemanager.sentinel";
        sentinelQueue.maxConcurrentOperationsCount = downloadQueue.maxConcurrentOperationsCount;

        sentinelDict = [NSMutableDictionary new];

        imageCache = aCache;
    }

    return self;
}

- (PLImageManagerRequestToken *)imageForIdentifier:(id <NSObject>)identifier placeholder:(UIImage *)placeholder callback:(void (^)(UIImage *image, BOOL isPlaceholder))callback {
    Class identifierClass = [provider identifierClass];
    if (![identifier isKindOfClass:identifierClass]) {
        @throw [NSException exceptionWithName:@"InvalidArgumentException" reason:[NSString stringWithFormat:@"The provided identifier \"%@\" is of a wrong type", identifier] userInfo:nil];
    }

    NSString *const opKey = [provider keyForIdentifier:identifier];

    PLImageManagerRequestToken *token = [[PLImageManagerRequestToken alloc] initWithKey:opKey];

    void (^notifyBlock)(UIImage *, BOOL) = ^(UIImage *image, BOOL isPlaceholder) {
        if (callback == nil) {
            return;
        }
        if ([NSThread currentThread] == [NSThread mainThread]) {
            callback(image, isPlaceholder);
        } else {
            //note: using NSThread would be nicer, but it doesn't support blocks so stick with GCD for now
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(image, isPlaceholder);
            });
        }
    };

    //first: fast memory only cache path
    UIImage *memoryCachedImage = [imageCache getWithKey:opKey onlyMemoryCache:YES];
    if (memoryCachedImage != nil) {
        [token markReady];
        notifyBlock(memoryCachedImage, NO);
    } else {
        if (placeholder != nil) {
            notifyBlock(placeholder, YES);
        }

        //second: slow paths
        PLImageManagerLoadOperation *sentinelOp = nil;
        __weak __block PLImageManagerLoadOperation *weakSentinelOp;
        @synchronized (sentinelDict) {
            sentinelOp = [sentinelDict objectForKey:opKey];
            if (sentinelOp == nil) {
                __weak typeof(provider)weakProvider = provider;
                __weak typeof(imageCache)weakImageCache = imageCache;
                __weak typeof(ioQueue)weakIOQueue = ioQueue;
                __weak typeof(sentinelDict)weakSentinelDict = sentinelDict;

                __weak __block PLImageManagerLoadOperation *weakDownloadOperation;
                __weak __block PLImageManagerLoadOperation *weakFileReadOperation;

                PLImageManagerLoadOperation *downloadOperation = [[PLImageManagerLoadOperation alloc] initWithKey:opKey loadBlock:^UIImage * {
                    NSError *error = NULL;
                    UIImage *image = [weakProvider downloadImageWithIdentifier:identifier error:&error];

                    if (error) {
                        NSLog(@"Error downloading image: %@", error);
                        return nil;
                    }

                    return image;
                }];
                weakDownloadOperation = downloadOperation;
                downloadOperation.opId = @"net";

                downloadOperation.readyBlock = ^(UIImage *image) {
                    if (image != nil) {
                        NSBlockOperation *storeOperation = [NSBlockOperation blockOperationWithBlock:^{
                            [weakImageCache set:image forKey:opKey];
                        }];
                        storeOperation.queuePriority = NSOperationQueuePriorityHigh;
                        [weakIOQueue addOperation:storeOperation];
                    }
                };

                PLImageManagerLoadOperation *fileReadOperation = [[PLImageManagerLoadOperation alloc] initWithKey:opKey loadBlock:^UIImage * {
                    return [weakImageCache getWithKey:opKey onlyMemoryCache:NO];
                }];
                weakFileReadOperation = fileReadOperation;
                fileReadOperation.opId = @"file";

                fileReadOperation.readyBlock = ^(UIImage *image) {
                    if (image != nil) {
                        [weakDownloadOperation cancel];
                    }
                };

                sentinelOp = [[PLImageManagerLoadOperation alloc] initWithKey:opKey loadBlock:^UIImage * {
                    if (weakFileReadOperation.image != nil) {
                        return weakFileReadOperation.image;
                    } else if (weakDownloadOperation.image != nil) {
                        return weakDownloadOperation.image;
                    } else {
                        if ([weakFileReadOperation isCancelled] && [weakDownloadOperation isCancelled]) {
                            [weakSentinelOp cancel];
                        }
                        return nil;
                    }
                }];
                sentinelOp.completionBlock = ^{
                    @synchronized (weakSentinelDict) {
                        [weakSentinelDict removeObjectForKey:opKey];
                    }
                };
                sentinelOp.onCancelBlock = ^{
                    @synchronized (weakSentinelDict) {
                        [weakSentinelDict removeObjectForKey:opKey];
                    }
                };
                sentinelOp.opId = @"sentinel";

                [downloadOperation addDependency:fileReadOperation];
                [sentinelOp addDependency:fileReadOperation];
                [sentinelOp addDependency:downloadOperation];

                [downloadQueue addOperation:downloadOperation];
                [ioQueue addOperation:fileReadOperation];
                [sentinelQueue addOperation:sentinelOp];
                [sentinelDict setObject:sentinelOp forKey:opKey];
            } else {
                [sentinelOp incrementUsage];
            }
            weakSentinelOp = sentinelOp;
        }

        token.onCancelBlock = ^{
            [weakSentinelOp decrementUsageAndCancelOnZero];
        };

        NSBlockOperation *notifyOperation = [NSBlockOperation blockOperationWithBlock:^{
            if (weakSentinelOp.isCancelled) {
                return;
            }
            [token markReady];
            notifyBlock(weakSentinelOp.image, NO);
        }];
        [notifyOperation addDependency:sentinelOp];
        notifyOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
        [sentinelQueue addOperation:notifyOperation];
    }

    return token;
}

- (void)clearCachedImageForIdentifier:(id <NSObject>)identifier{
    Class identifierClass = [provider identifierClass];
    if (![identifier isKindOfClass:identifierClass]) {
        @throw [NSException exceptionWithName:@"InvalidArgumentException" reason:[NSString stringWithFormat:@"The provided identifier \"%@\" is of a wrong type", identifier] userInfo:nil];
    }

    NSString *const opKey = [provider keyForIdentifier:identifier];
    [imageCache removeImageWithKey:opKey];
}

- (void)clearCache {
    [imageCache clearMemoryCache];
    [imageCache clearFileCache];
}

- (void)deferCurrentDownloads {
    @synchronized (sentinelDict) {
        for (PLImageManagerLoadOperation *op in [sentinelDict allValues]) {
            for (PLImageManagerLoadOperation *dependentOp in op.dependencies) {
                dependentOp.queuePriority = NSOperationQueuePriorityLow;
            }
        }
    }
}

@end

@implementation PLImageManagerRequestToken {

}

@synthesize key = key;
@synthesize isCanceled = isCanceled;
@synthesize isReady = isReady;
@synthesize onCancelBlock = onCancelBlock;

- (id)initWithKey:(NSString *)aKey {
    self = [super init];
    if (self) {
        key = aKey;
        isCanceled = NO;
        isReady = NO;
    }
    return self;
}

- (void)markReady {
    if (isCanceled){
        return;
    }
    isReady = YES;
}

- (BOOL)isReady {
    return isReady;
}

- (void)cancel {
    if (isCanceled || isReady) {
        return;
    }
    isCanceled = YES;
    if (onCancelBlock){
        onCancelBlock();
    }
}

@end