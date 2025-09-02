//
//  AudioUnitRecorder.h
//  AudioUnitDemo
//
//  Created by m103002161 on 2023/3/26.
//

#import <Foundation/Foundation.h>
#import "RecorderDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioUnitPlayer;

@interface AudioUnitAECRecorder : NSObject

@property(nonatomic,strong) id<AECRecorderDelegate> aecRecorderDelegate;
@property(nonatomic,weak) AudioUnitPlayer *referencePlayer; // For AEC reference signal

-(void)startRecord:(NSString *)filePath aecOn:(BOOL)aecOn;
-(void)stopRecord;
-(BOOL)isStated;

@end

NS_ASSUME_NONNULL_END
