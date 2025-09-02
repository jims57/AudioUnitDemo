//
//  AudioUnitAECRecorder.m
//  AudioUnitDemo
//
//  Created by devnn on 2023/3/26.
//

#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIApplication.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "AudioUnitAECRecorder.h"
#import "RecorderDelegate.h"
#import "CommonDefine.h"



@interface AudioUnitAECRecorder(){
    AUNode remoteIONode;
    AudioUnit remoteIOUnit;
    AudioStreamBasicDescription mAudioFormat;
}
@property(nonatomic,assign) RecordState state;
@property(nonatomic,copy) NSString *originAudioSessionCategory;
@property(nonatomic,copy) NSString *filePath;
@property(nonatomic,assign) FILE *file;
@property(nonatomic,assign) BOOL isAecOn;//是否开启AEC
@property(nonatomic,strong) MPVolumeView *volumeView;
@property(nonatomic,assign) float savedVolume;

@end

@implementation AudioUnitAECRecorder

-(id)init{
    self = [super init];
    if(self){
        self.file = NULL;
        // Initialize volume view for programmatic volume control
        self.volumeView = [[MPVolumeView alloc] init];
        self.volumeView.hidden = YES; // Keep it hidden but functional
        self.savedVolume = 0.0;
    }
    return self;
}


/**
 录制回调
 */
OSStatus AECAudioInputCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *__nullable ioData) {
    NSLog(@"AECAudioInputCallback");
    AudioUnitAECRecorder *recorder = (__bridge AudioUnitAECRecorder *)inRefCon;
    
    AudioBuffer buffer;
    
    /**
     on this point we define the number of channels, which is mono
     for the iphone. the number of frames is usally 512 or 1024.
     */
    UInt32 size = inNumberFrames * recorder->mAudioFormat.mBytesPerFrame;
    buffer.mDataByteSize = size; // sample size
    buffer.mNumberChannels = 1; // one channel
    buffer.mData = malloc(size); // buffer size
    
    // we put our buffer into a bufferlist array for rendering
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0] = buffer;
    
    OSStatus status = noErr;
    
    status = AudioUnitRender(recorder->remoteIOUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList);
    
    if (status != noErr) {
        printf("AudioUnitRender %d \n", (int)status);
        return status;
    }
    
    [recorder writePCMData:buffer.mData size:buffer.mDataByteSize];
    free(buffer.mData);
    return status;
}


-(void)startRecord:(NSString *)filePath aecOn:(BOOL)aecOn{
    self.filePath = filePath;
    self.isAecOn = aecOn;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if ([audioSession respondsToSelector:@selector(requestRecordPermission:)]) {
        [audioSession performSelector:@selector(requestRecordPermission:) withObject:^(BOOL allow){
            if(allow){
                NSLog(@"已经拥有麦克风权限");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self realStart];
                });
            }else{
                // no permission
                NSLog(@"没有麦克风权限");
            }
        }];
    }
    
}

-(void)realStart{
    [self initAudioSession];
    [self initAudioUnit];
    [self initFormat];
    [self initInputCallBack];
    [self startRecord];
}




- (void)writePCMData:(char *)buffer size:(int)size {
    if (!self.file) {
        self.file = fopen(self.filePath.UTF8String, "w");
    }
    fwrite(buffer, size, 1, self.file);
}


-(void)initAudioSession{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    self.originAudioSessionCategory = audioSession.category;
    NSError *error = nil;
    
    // Use PlayAndRecord without ducking to maintain normal volume
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord 
                  withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionMixWithOthers
                        error:&error];
    if (error) {
        NSLog(@"Audio session category error: %@", error.localizedDescription);
    }

    // Set the mode to VoiceChat for optimal AEC performance, as recommended by Apple.
    [audioSession setMode:AVAudioSessionModeVoiceChat error:&error];
    if (error) {
        NSLog(@"Audio session mode error: %@", error.localizedDescription);
    }
    
    
    // Set preferred sample rate to match AudioUnit
    [audioSession setPreferredSampleRate:16000 error:&error];
    if (error) {
        NSLog(@"Audio session sample rate error: %@", error.localizedDescription);
    }
    
    [audioSession setPreferredIOBufferDuration:0.02 error:&error];
    if (error) {
        NSLog(@"Audio session buffer duration error: %@", error.localizedDescription);
    }
    
    // Set input gain to ensure adequate signal level for AEC reference
    if ([audioSession isInputGainSettable]) {
        [audioSession setInputGain:0.8 error:&error];
        if (error) {
            NSLog(@"Audio session input gain error: %@", error.localizedDescription);
        } else {
            NSLog(@"Input gain set to 0.8 for optimal AEC performance");
        }
    }
    
    [audioSession setActive:YES error:&error];
    if (error) {
        NSLog(@"Audio session activate error: %@", error.localizedDescription);
    }
}


/**
 初始化AudioUnit
 */
-(void)initAudioUnit{
    AudioComponentDescription componentDesc;
    componentDesc.componentType = kAudioUnitType_Output;
    if(self.isAecOn){
        componentDesc.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    }else{
        componentDesc.componentSubType = kAudioUnitSubType_RemoteIO;
    }
    componentDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    componentDesc.componentFlags = 0;
    componentDesc.componentFlagsMask = 0;
    
    AudioComponent audioCompnent = AudioComponentFindNext(NULL, &componentDesc);
    OSStatus status = AudioComponentInstanceNew(audioCompnent, &remoteIOUnit);
    CheckError(status, "创建unit失败");
    
    UInt32 enableFlag = 1;
    UInt32 unableFlag = 0;
    
    // Disable audio output on the AEC unit to prevent it from interfering with the player.
    // The AEC will still run correctly as long as the session is active.
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output,
                                    0,
                                    &unableFlag,
                                    sizeof(unableFlag)),
               "Disable output of bus 0 failed");
    //开启麦克风
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Input,
                                    1,
                                    &enableFlag,
                                    sizeof(enableFlag)),
               "Open input of bus 1 failed");
    
}

/**
 音频参数
 */
-(void)initFormat{
    // VoiceProcessingIO works best with 8kHz or 16kHz, mono, 16-bit
    mAudioFormat.mSampleRate = 16000;
    mAudioFormat.mFormatID = kAudioFormatLinearPCM;
    mAudioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    mAudioFormat.mReserved = 0;
    mAudioFormat.mChannelsPerFrame = 1;
    mAudioFormat.mBitsPerChannel = 16;
    mAudioFormat.mFramesPerPacket = 1;
    mAudioFormat.mBytesPerFrame = (mAudioFormat.mBitsPerChannel / 8) * mAudioFormat.mChannelsPerFrame;
    mAudioFormat.mBytesPerPacket = mAudioFormat.mFramesPerPacket * mAudioFormat.mBytesPerFrame;
    
    UInt32 size = sizeof(mAudioFormat);
    
    // Set format for microphone input (bus 1)
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    1,
                                    &mAudioFormat,
                                    size),
               "Set input format failed");
    
    // Set format for speaker output (bus 0)
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input,
                                    0,
                                    &mAudioFormat,
                                    size),
               "Set output format failed");
    
    // Configure VoiceProcessingIO for optimal AEC
    if (self.isAecOn) {
        // Enable AEC (0 = enable, 1 = bypass/disable)
        UInt32 bypassAEC = 0;
        OSStatus aecStatus = AudioUnitSetProperty(remoteIOUnit,
                                        kAUVoiceIOProperty_BypassVoiceProcessing,
                                        kAudioUnitScope_Global,
                                        0,
                                        &bypassAEC,
                                        sizeof(bypassAEC));
        if (aecStatus != noErr) {
            NSLog(@"Enable AEC failed with error: %d", (int)aecStatus);
        }
        
        // Disable AGC to reduce processing conflicts
        UInt32 agcDisable = 0;
        OSStatus agcStatus = AudioUnitSetProperty(remoteIOUnit,
                                        kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                        kAudioUnitScope_Global,
                                        0,
                                        &agcDisable,
                                        sizeof(agcDisable));
        if (agcStatus != noErr) {
            NSLog(@"Disable AGC failed with error: %d", (int)agcStatus);
        }
    }
}


/**
 音频输入回调:录音
 */

- (void)initInputCallBack {
    // Set input callback for recording
    AURenderCallbackStruct inputCallbackStruct;
    inputCallbackStruct.inputProc = AECAudioInputCallback;
    inputCallbackStruct.inputProcRefCon = (__bridge void *)(self);
    OSStatus status = AudioUnitSetProperty(remoteIOUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Output, 0, &inputCallbackStruct, sizeof(inputCallbackStruct));
    CheckError(status, "设置采集回调失败");
    
}



-(void)startRecord{
    CheckError(AudioUnitInitialize(remoteIOUnit),"AudioUnitInitialize error");
    OSStatus status = AudioOutputUnitStart(remoteIOUnit);
    CheckError(status,"AudioOutputUnitStart error");
    if(status==0){
        self.state=STATE_START;
        
        // Save current volume and maintain it to counteract AEC volume reduction
        [self saveAndMaintainVolume];
        
        [self.aecRecorderDelegate aecRecorderDidStart];
    }
}

- (void)stopRecord{
    NSLog(@"audio,record stop");
    if(self.state == STATE_STOP){
        NSLog(@"audio,in recorder stop, state has stopped!");
        return;
    }
    
    AudioOutputUnitStop(remoteIOUnit);
    
    //    AudioUnitUninitialize(remoteIOUnit);
    
    AudioComponentInstanceDispose(remoteIOUnit);
    
    // Restore original volume level
    [self restoreVolume];
    
    [[AVAudioSession sharedInstance] setCategory:self.originAudioSessionCategory error:nil];
    
    self.state = STATE_STOP;
    
    self.file=NULL;
    
    [self.aecRecorderDelegate aecRecorderDidStop];
    
    //    [self audioUnitStopPlay];
}

/**
 运行时设置AEC开启和关闭
 */
-(void)setAecOn:(BOOL)aecOn{
    NSLog(@"setAecOn:%d",aecOn);
    self.isAecOn = aecOn;
    
    // 0 = enable AEC, 1 = bypass/disable AEC
    UInt32 bypassFlag = aecOn ? 0 : 1;
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAUVoiceIOProperty_BypassVoiceProcessing,
                                    kAudioUnitScope_Global,
                                    0,
                                    &bypassFlag,
                                    sizeof(bypassFlag)),
               "Set AEC bypass failed");
    NSLog(@"AEC bypass flag set to: %d (0=enabled, 1=disabled)", bypassFlag);
}



- (void)saveAndMaintainVolume {
    // Save current volume level
    UISlider *volumeSlider = nil;
    for (UIView *view in self.volumeView.subviews) {
        if ([view isKindOfClass:[UISlider class]]) {
            volumeSlider = (UISlider *)view;
            break;
        }
    }
    
    if (volumeSlider) {
        self.savedVolume = volumeSlider.value;
        NSLog(@"Saved current volume: %.2f", self.savedVolume);
        
        // Maintain the volume level to counteract AEC-induced reduction
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            volumeSlider.value = self.savedVolume;
            NSLog(@"Restored volume to: %.2f", self.savedVolume);
        });
    }
}

- (void)restoreVolume {
    if (self.savedVolume > 0.0) {
        UISlider *volumeSlider = nil;
        for (UIView *view in self.volumeView.subviews) {
            if ([view isKindOfClass:[UISlider class]]) {
                volumeSlider = (UISlider *)view;
                break;
            }
        }
        
        if (volumeSlider) {
            volumeSlider.value = self.savedVolume;
            NSLog(@"Volume restored to original level: %.2f", self.savedVolume);
        }
    }
}

-(void)dealloc{
    //    [self _unregisterForBackgroundNotifications];
    
    //    [self stop:NO];
    
    //    self.originCategory=nil;
    
}

- (NSString *)documentsPath:(NSString *)fileName {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    return [documentsDirectory stringByAppendingPathComponent:fileName];
}

-(BOOL)isStated{
    return self.state==STATE_START;
}


@end
