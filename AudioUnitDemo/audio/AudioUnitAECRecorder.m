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
    AudioStreamBasicDescription audioFormat;
}
@property(nonatomic,assign) RecordState state;
@property(nonatomic,copy) NSString *originAudioSessionCategory;
@property(nonatomic,copy) NSString *recordFilePath;
@property(nonatomic,assign) FILE *recordFile;
@property(nonatomic,assign) BOOL isAecOn;//是否开启AEC
@property(nonatomic,strong) MPVolumeView *volumeView;
@property(nonatomic,assign) float savedVolume;
@property(nonatomic,strong) NSTimer *volumeMaintenanceTimer;
@property(nonatomic,strong) NSString *playbackFilePath;
@property(nonatomic,assign) FILE *playbackFile;
@property(nonatomic,assign) BOOL isPlaybackActive;
@property(nonatomic,assign) BOOL shouldLoopPlayback;
@property(nonatomic,assign) long playbackFileSize;
@property(nonatomic,assign) long playbackCurrentPosition;
@property(nonatomic,strong) NSMutableData *referenceAudioBuffer; // Buffer for reference signal

@end

@implementation AudioUnitAECRecorder

-(id)init{
    self = [super init];
    if(self){
        self.recordFile = NULL;
        // Initialize volume view for programmatic volume control
        self.volumeView = [[MPVolumeView alloc] init];
        self.volumeView.hidden = YES; // Keep it hidden but functional
        self.savedVolume = 0.0;
        // Initialize reference audio buffer for AEC
        self.referenceAudioBuffer = [[NSMutableData alloc] init];
    }
    return self;
}


/**
 录制回调
 */
/**
 AEC Output callback - provides reference signal for echo cancellation
 */
static OSStatus AECAudioOutputCallback(void *inRefCon,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData) {
    AudioUnitAECRecorder *recorder = (__bridge AudioUnitAECRecorder *)inRefCon;
    
    // Handle unified VPIO playback
    if (recorder.isPlaybackActive && recorder.playbackFile) {
        UInt32 bytesToRead = inNumberFrames * recorder->audioFormat.mBytesPerFrame;
        
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            UInt32 bytesRead = (UInt32)fread(ioData->mBuffers[i].mData, 1, bytesToRead, recorder.playbackFile);
            
            if (bytesRead < bytesToRead) {
                // Handle end of file
                if (recorder.shouldLoopPlayback) {
                    // Reset to beginning for loop
                    fseek(recorder.playbackFile, 0, SEEK_SET);
                    recorder.playbackCurrentPosition = 0;
                    // Fill remaining buffer with beginning of file
                    UInt32 remainingBytes = bytesToRead - bytesRead;
                    if (remainingBytes > 0) {
                        fread((char*)ioData->mBuffers[i].mData + bytesRead, 1, remainingBytes, recorder.playbackFile);
                    }
                } else {
                    // Fill remaining buffer with silence and stop playback
                    memset((char*)ioData->mBuffers[i].mData + bytesRead, 0, bytesToRead - bytesRead);
                    recorder.isPlaybackActive = NO;
                }
            }
            
            ioData->mBuffers[i].mDataByteSize = bytesToRead;
        }
        
        recorder.playbackCurrentPosition += inNumberFrames * recorder->audioFormat.mBytesPerFrame;
    } else {
        // Fill with silence when no playback
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
    }
    
    return noErr;
}

OSStatus AECAudioInputCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *__nullable ioData) {
    AudioUnitAECRecorder *recorder = (__bridge AudioUnitAECRecorder *)inRefCon;
    
    AudioBuffer buffer;
    
    /**
     on this point we define the number of channels, which is mono
     for the iphone. the number of frames is usally 512 or 1024.
     */
    UInt32 size = inNumberFrames * recorder->audioFormat.mBytesPerFrame;
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
        printf("AudioUnitRender error: %d \n", (int)status);
        free(buffer.mData);
        return status;
    }
    
    [recorder writePCMData:buffer.mData size:buffer.mDataByteSize];
    free(buffer.mData);
    return status;
}


-(void)startRecord:(NSString *)filePath aecOn:(BOOL)aecOn{
    self.recordFilePath = filePath;
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
    if (!self.recordFile) {
        self.recordFile = fopen(self.recordFilePath.UTF8String, "w");
    }
    fwrite(buffer, size, 1, self.recordFile);
}


-(void)initAudioSession{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    self.originAudioSessionCategory = audioSession.category;
    NSError *error = nil;
    
    // Deactivate session first to avoid conflicts
    [audioSession setActive:NO error:nil];
    
    NSUInteger sessionOptions = AVAudioSessionCategoryOptionDefaultToSpeaker | 
                               AVAudioSessionCategoryOptionMixWithOthers;
    
    // Set category first
    BOOL categorySuccess = [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord 
                                          withOptions:sessionOptions
                                                error:&error];
    if (!categorySuccess || error) {
        NSLog(@"Audio session category error: %@", error.localizedDescription);
        // Try simpler category
        error = nil;
        [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
        if (error) {
            NSLog(@"Fallback category also failed: %@", error.localizedDescription);
            return;
        }
    }

    // Set mode - try Default first for better compatibility
    [audioSession setMode:AVAudioSessionModeDefault error:&error];
    if (error) {
        NSLog(@"Audio session Default mode error: %@", error.localizedDescription);
        error = nil; // Clear error and continue
    } else {
        NSLog(@"Audio session mode set to Default for compatibility");
    }
    
    // Set sample rate with error handling
    [audioSession setPreferredSampleRate:16000 error:&error];
    if (error) {
        NSLog(@"Audio session sample rate error: %@", error.localizedDescription);
        error = nil; // Clear error and continue
    } else {
        NSLog(@"Sample rate set to 16kHz");
    }
    
    // Set buffer duration with error handling
    [audioSession setPreferredIOBufferDuration:0.02 error:&error];
    if (error) {
        NSLog(@"Audio session buffer duration error: %@", error.localizedDescription);
        error = nil; // Clear error and continue
    } else {
        NSLog(@"Buffer duration set to 20ms");
    }
    
    // Activate session
    [audioSession setActive:YES error:&error];
    if (error) {
        NSLog(@"Audio session activate error: %@", error.localizedDescription);
        return;
    }
    
    // Force speaker output
    [audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
    if (error) {
        NSLog(@"Failed to override audio output to speaker: %@", error.localizedDescription);
    } else {
        NSLog(@"Successfully configured speaker output");
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioSessionInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:audioSession];
}


/**
 初始化AudioUnit
 */
-(void)initAudioUnit{
    AudioComponentDescription componentDesc;
    componentDesc.componentType = kAudioUnitType_Output;
    
    // Use VoiceProcessingIO for unified playback/recording, RemoteIO for playback-only
    BOOL useVPIO = self.isAecOn || self.isPlaybackActive;
    if(useVPIO){
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
    
    // Always enable output for playback
    CheckError(AudioUnitSetProperty(remoteIOUnit,
                                    kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output,
                                    0,
                                    &enableFlag,
                                    sizeof(enableFlag)),
               "Enable output of bus 0 failed");
    
    // Enable input only for recording or when AEC is on
    if (self.isAecOn || self.state == STATE_START) {
        CheckError(AudioUnitSetProperty(remoteIOUnit,
                                        kAudioOutputUnitProperty_EnableIO,
                                        kAudioUnitScope_Input,
                                        1,
                                        &enableFlag,
                                        sizeof(enableFlag)),
                   "Open input of bus 1 failed");
    }
    
    NSLog(@"AudioUnit initialized with %@ for %@", 
          useVPIO ? @"VoiceProcessingIO" : @"RemoteIO",
          self.isPlaybackActive ? @"playback" : @"recording");
}

/**
 音频参数
 */
-(void)initFormat{
    // VoiceProcessingIO works best with 8kHz or 16kHz, mono, 16-bit
    audioFormat.mSampleRate = 16000;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mReserved = 0;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = (audioFormat.mBitsPerChannel / 8) * audioFormat.mChannelsPerFrame;
    audioFormat.mBytesPerPacket = audioFormat.mFramesPerPacket * audioFormat.mBytesPerFrame;
    
    UInt32 size = sizeof(audioFormat);
    
    // Set format for microphone input (bus 1) - only if input is enabled
    if (self.isAecOn || self.state == STATE_START) {
        OSStatus inputStatus = AudioUnitSetProperty(remoteIOUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Output,
                                        1,
                                        &audioFormat,
                                        size);
        if (inputStatus != noErr) {
            NSLog(@"Set input format failed with error: %d", (int)inputStatus);
        } else {
            NSLog(@"Input format set successfully");
        }
    }
    
    // Set format for speaker output (bus 0)
    OSStatus outputStatus = AudioUnitSetProperty(remoteIOUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input,
                                    0,
                                    &audioFormat,
                                    size);
    if (outputStatus != noErr) {
        NSLog(@"Set output format failed with error: %d", (int)outputStatus);
    } else {
        NSLog(@"Output format set successfully");
    }
    
    // Configure VoiceProcessingIO for balanced AEC - echo removal with minimal voice suppression
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
        } else {
            NSLog(@"AEC enabled for echo cancellation");
        }
        
        // Disable AGC to prevent voice suppression but keep AEC active
        UInt32 agcEnable = 0;
        OSStatus agcStatus = AudioUnitSetProperty(remoteIOUnit,
                                        kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                        kAudioUnitScope_Global,
                                        0,
                                        &agcEnable,
                                        sizeof(agcEnable));
        if (agcStatus != noErr) {
            NSLog(@"Disable AGC failed with error: %d", (int)agcStatus);
        } else {
            NSLog(@"AGC disabled - AEC active without voice level adjustment");
        }
        
        // Disable mute on/off to prevent voice cutting
        UInt32 muteOutput = 0;
        OSStatus muteStatus = AudioUnitSetProperty(remoteIOUnit,
                                         kAUVoiceIOProperty_MuteOutput,
                                         kAudioUnitScope_Global,
                                         0,
                                         &muteOutput,
                                         sizeof(muteOutput));
        if (muteStatus == noErr) {
            NSLog(@"Output muting disabled for continuous voice");
        }
        
        NSLog(@"VoiceProcessingIO configured: AEC enabled, AGC disabled for voice preservation");
    }
}

- (void)initInputCallBack {
    // Set input callback only if recording or AEC is enabled
    if (self.isAecOn || self.state == STATE_START) {
        AURenderCallbackStruct inputCallbackStruct;
        inputCallbackStruct.inputProc = AECAudioInputCallback;
        inputCallbackStruct.inputProcRefCon = (__bridge void *)(self);
        OSStatus status = AudioUnitSetProperty(remoteIOUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Output, 0, &inputCallbackStruct, sizeof(inputCallbackStruct));
        CheckError(status, "设置采集回调失败");
    }
    
    // Always set output callback for playback (both standalone and with AEC)
    AURenderCallbackStruct outputCallbackStruct;
    outputCallbackStruct.inputProc = AECAudioOutputCallback;
    outputCallbackStruct.inputProcRefCon = (__bridge void *)(self);
    OSStatus outputStatus = AudioUnitSetProperty(remoteIOUnit,
                                               kAudioUnitProperty_SetRenderCallback,
                                               kAudioUnitScope_Input,
                                               0,
                                               &outputCallbackStruct,
                                               sizeof(outputCallbackStruct));
    CheckError(outputStatus, "设置输出回调失败");
    NSLog(@"Output callback configured for %@", 
          self.isPlaybackActive ? @"standalone playback" : @"AEC reference signal");
}

-(void)startRecord{
    CheckError(AudioUnitInitialize(remoteIOUnit),"AudioUnitInitialize error");
    OSStatus status = AudioOutputUnitStart(remoteIOUnit);
    CheckError(status,"AudioOutputUnitStart error");
    if(status==0){
        self.state=STATE_START;
        
        // Force hands-free speaker output immediately when AEC starts
        NSError *error = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
        if (!error) {
            NSLog(@"Forced speaker output for hands-free AEC recording");
        }
        
        // Save current volume and maintain it to counteract AEC volume reduction
        [self saveAndMaintainVolume];
        
        [self.aecRecorderDelegate aecRecorderDidStart];
    }
}

- (void)stopRecord{
    if(self.state == STATE_STOP){
        return;
    }
    self.state = STATE_STOP;
    
    // Stop playback if active
    [self stopPlayback];
    
    // Stop volume maintenance timer
    if (self.volumeMaintenanceTimer) {
        [self.volumeMaintenanceTimer invalidate];
        self.volumeMaintenanceTimer = nil;
    }
    
    // Restore original volume
    [self restoreOriginalVolume];
    
    OSStatus status = AudioOutputUnitStop(remoteIOUnit);
    CheckError(status, "停止录音失败");
    
    if(self.recordFile){
        fclose(self.recordFile);
        self.recordFile = NULL;
    }
    
    if(self.aecRecorderDelegate && [self.aecRecorderDelegate respondsToSelector:@selector(aecRecorderDidStop)]){
        [self.aecRecorderDelegate aecRecorderDidStop];
    }
    
    // Restore original audio session category
    if (self.originAudioSessionCategory) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setCategory:self.originAudioSessionCategory error:&error];
        if (error) {
            NSLog(@"Failed to restore original audio session category: %@", error.localizedDescription);
        }
    }
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

- (void)restoreOriginalVolume {
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

- (void)ensureMaximumSpeakerVolume {
    UISlider *volumeSlider = nil;
    for (UIView *view in self.volumeView.subviews) {
        if ([view isKindOfClass:[UISlider class]]) {
            volumeSlider = (UISlider *)view;
            break;
        }
    }
    
    if (volumeSlider) {
        float currentVolume = volumeSlider.value;
        if (currentVolume < 0.9) {
            volumeSlider.value = 0.9;
            NSLog(@"Ensured maximum speaker volume: %.2f -> 0.9 for hands-free playback", currentVolume);
        }
    }
    
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
    if (!error) {
        NSLog(@"Re-forced speaker output for maximum hands-free volume");
    }
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification {
    NSNumber *interruptionType = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    
    if (interruptionType.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        NSLog(@"Audio session interrupted - pausing AEC recording");
        if (self.state == STATE_START) {
            AudioOutputUnitStop(remoteIOUnit);
        }
    } else if (interruptionType.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        NSLog(@"Audio session interruption ended - resuming AEC recording");
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (!error && self.state == STATE_START) {
            AudioOutputUnitStart(remoteIOUnit);
            // Re-force speaker output after interruption
            [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
        }
    }
}

-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.recordFile) {
        fclose(self.recordFile);
        self.recordFile = NULL;
    }
    if (self.playbackFile) {
        fclose(self.playbackFile);
        self.playbackFile = NULL;
    }
}

- (NSString *)documentsPath:(NSString *)fileName {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    return [documentsDirectory stringByAppendingPathComponent:fileName];
}

-(BOOL)isStated{
    return self.state == STATE_START;
}

// MARK: - Unified VPIO Playback Methods

-(void)startPlayback:(NSString *)filePath loop:(BOOL)loop {
    if (self.isPlaybackActive) {
        [self stopPlayback];
    }
    
    self.playbackFilePath = filePath;
    self.shouldLoopPlayback = loop;
    
    // Open playback file
    self.playbackFile = fopen(filePath.UTF8String, "r");
    if (!self.playbackFile) {
        NSLog(@"Failed to open playback file: %@", filePath);
        return;
    }
    
    // Get file size
    fseek(self.playbackFile, 0, SEEK_END);
    self.playbackFileSize = ftell(self.playbackFile);
    fseek(self.playbackFile, 0, SEEK_SET);
    self.playbackCurrentPosition = 0;
    
    // Initialize AudioUnit if not already initialized for recording
    if (self.state != STATE_START) {
        [self initializeAudioUnitForPlayback];
    }
    
    self.isPlaybackActive = YES;
    NSLog(@"Started unified VPIO playback: %@, loop: %@", filePath, loop ? @"YES" : @"NO");
}

-(void)stopPlayback {
    if (!self.isPlaybackActive) {
        return;
    }
    
    self.isPlaybackActive = NO;
    
    if (self.playbackFile) {
        fclose(self.playbackFile);
        self.playbackFile = NULL;
    }
    
    // Stop AudioUnit if only used for playback (not recording)
    if (self.state != STATE_START) {
        [self stopAudioUnitForPlayback];
    }
    
    NSLog(@"Stopped unified VPIO playback");
}

-(BOOL)isPlaybackStarted {
    return self.isPlaybackActive;
}

// MARK: - AudioUnit Management for Standalone Playback

-(void)initializeAudioUnitForPlayback {
    NSLog(@"Initializing AudioUnit for standalone playback");
    
    // Initialize audio session for playback
    [self initAudioSession];
    
    // Initialize AudioUnit components
    [self initAudioUnit];
    [self initFormat];
    [self initInputCallBack];
    
    // Initialize and start AudioUnit
    CheckError(AudioUnitInitialize(remoteIOUnit), "AudioUnitInitialize for playback failed");
    OSStatus status = AudioOutputUnitStart(remoteIOUnit);
    CheckError(status, "AudioOutputUnitStart for playback failed");
    
    if (status == 0) {
        NSLog(@"AudioUnit started successfully for standalone playback");
        
        // Ensure speaker output and volume for playback
        [self ensureMaximumSpeakerVolume];
    }
}

-(void)stopAudioUnitForPlayback {
    NSLog(@"Stopping AudioUnit for standalone playback");
    
    OSStatus status = AudioOutputUnitStop(remoteIOUnit);
    CheckError(status, "AudioOutputUnitStop for playback failed");
    
    if (status == 0) {
        NSLog(@"AudioUnit stopped successfully for standalone playback");
    }
    
    // Restore original audio session category
    if (self.originAudioSessionCategory) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setCategory:self.originAudioSessionCategory error:&error];
        if (error) {
            NSLog(@"Failed to restore original audio session category: %@", error.localizedDescription);
        }
    }
}

@end
