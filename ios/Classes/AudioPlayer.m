#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

// TODO: Check for and report invalid state transitions.
@implementation AudioPlayer {
	NSObject<FlutterPluginRegistrar>* _registrar;
	FlutterMethodChannel* _methodChannel;
	FlutterEventChannel* _eventChannel;
	FlutterEventSink _eventSink;
	NSString* _playerId;
	AVPlayer* _player;
	enum PlaybackState _state;
	enum PlaybackState _stateBeforeSeek;
	long long _updateTime;
	int _updatePosition;
	int _seekPos;
	FlutterResult _connectionResult;
	id _endObserver;
	id _timeObserver;
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar playerId:(NSString*)idParam {
	self = [super init];
	NSAssert(self, @"super init cannot be nil");
	_registrar = registrar;
	_playerId = idParam;
	_methodChannel = [FlutterMethodChannel
		methodChannelWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.methods.%@", _playerId]
		      binaryMessenger:[registrar messenger]];
	_eventChannel = [FlutterEventChannel
		eventChannelWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.events.%@", _playerId]
		     binaryMessenger:[registrar messenger]];
	[_eventChannel setStreamHandler:self];
	_state = none;
	_stateBeforeSeek = none;
	_player = nil;
	_seekPos = -1;
	_endObserver = 0;
	_timeObserver = 0;
	__weak __typeof__(self) weakSelf = self;
	[_methodChannel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
		  [weakSelf handleMethodCall:call result:result];
	}];
	return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
	NSArray* args = (NSArray*)call.arguments;
	if ([@"setUrl" isEqualToString:call.method]) {
		[self setUrl:args[0] result:result];
	} else if ([@"setClip" isEqualToString:call.method]) {
		[self setClip:args[0] end:args[1]];
		result(nil);
	} else if ([@"play" isEqualToString:call.method]) {
		[self play];
		result(nil);
	} else if ([@"pause" isEqualToString:call.method]) {
		[self pause];
		result(nil);
	} else if ([@"stop" isEqualToString:call.method]) {
		[self stop];
		result(nil);
	} else if ([@"setVolume" isEqualToString:call.method]) {
		[self setVolume:(float)[args[0] doubleValue]];
		result(nil);
	} else if ([@"setSpeed" isEqualToString:call.method]) {
		[self setSpeed:(float)[args[0] doubleValue]];
		result(nil);
	} else if ([@"seek" isEqualToString:call.method]) {
		[self seek:[args[0] intValue] result:result];
		result(nil);
	} else if ([@"dispose" isEqualToString:call.method]) {
		[self dispose];
		result(nil);
	} else {
		result(FlutterMethodNotImplemented);
	}
	// TODO
	/* } catch (Exception e) { */
	/* 	e.printStackTrace(); */
	/* 	result.error("Error", null, null); */
	/* } */
}

- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
	_eventSink = eventSink;
	return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
	_eventSink = nil;
	return nil;
}

- (void)checkForDiscontinuity {
	if (!_eventSink) return;
	if (_state != playing && _state != buffering) return;
	long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
	int position = [self getCurrentPosition];
	long long timeSinceLastUpdate = now - _updateTime;
	long long expectedPosition = _updatePosition + (long long)(timeSinceLastUpdate * _player.rate);
	long long drift = position - expectedPosition;
	// Update if we've drifted or just started observing
	if (_updateTime == 0L) {
		[self broadcastPlaybackEvent];
	} else if (drift < -100) {
		NSLog(@"time discontinuity detected: %lld", drift);
		[self setPlaybackState:buffering];
	} else if (_state == buffering) {
		[self setPlaybackState:playing];
	}
}

- (void)broadcastPlaybackEvent {
	long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
	_updatePosition = [self getCurrentPosition];
	_updateTime = now;
	_eventSink(@[
		// state
		@(_state),
		// updatePosition
		@(_updatePosition),
		// updateTime
		@(_updateTime),
	]);
}

- (int)getCurrentPosition {
	if (_state == none || _state == connecting) {
		return 0;
	} else if (_seekPos != -1) {
		return _seekPos;
	} else {
		return (int)(1000 * CMTimeGetSeconds([_player currentTime]));
	}
}

- (void)setPlaybackState:(enum PlaybackState)state {
	//enum PlaybackState oldState = _state;
	_state = state;
	// TODO: Investigate when we need to start and stop
	// observing item position.
	/* if (oldState != playing && state == playing) { */
	/* 	[self startObservingPosition]; */
	/* } */
	[self broadcastPlaybackEvent];
}

- (void)setUrl:(NSString*)url result:(FlutterResult)result {
	// TODO: error if already connecting
	_connectionResult = result;
	[self setPlaybackState:connecting];
	if (_player) {
		[[_player currentItem] removeObserver:self forKeyPath:@"status"];
		[[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
		_endObserver = 0;
	}
	AVPlayerItem* playerItem = [[AVPlayerItem alloc] initWithURL:[NSURL URLWithString:url]];
	[playerItem addObserver:self
		     forKeyPath:@"status"
			options:NSKeyValueObservingOptionNew
			context:nil];
	// TODO: Add observer for _endObserver.
	_endObserver = [[NSNotificationCenter defaultCenter]
		addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
			    object:playerItem
			     queue:nil
			usingBlock:^(NSNotification* note) {
				NSLog(@"Reached play end time");
				[self complete];
			}
	];
	if (_player) {
		[_player replaceCurrentItemWithPlayerItem:playerItem];
	} else {
		_player = [[AVPlayer alloc] initWithPlayerItem:playerItem];
	}
	if (_timeObserver) {
		[_player removeTimeObserver:_timeObserver];
		_timeObserver = 0;
	}
	// TODO: learn about the different ways to define weakSelf.
	//__weak __typeof__(self) weakSelf = self;
	//typeof(self) __weak weakSelf = self;
	__unsafe_unretained typeof(self) weakSelf = self;
	_timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(200, 1000)
		queue:nil
		usingBlock:^(CMTime time) {
			[weakSelf checkForDiscontinuity];
		}
	];
	// We send result after the playerItem is ready in observeValueForKeyPath.
}

- (void)observeValueForKeyPath:(NSString *)keyPath
		ofObject:(id)object
		change:(NSDictionary<NSString *,id> *)change
		context:(void *)context {

	if ([keyPath isEqualToString:@"status"]) {
		AVPlayerItemStatus status = AVPlayerItemStatusUnknown;
		NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
		if ([statusNumber isKindOfClass:[NSNumber class]]) {
			status = statusNumber.integerValue;
		}
		switch (status) {
			case AVPlayerItemStatusReadyToPlay:
				[self setPlaybackState:stopped];
				_connectionResult(@((int)(1000 * CMTimeGetSeconds([[_player currentItem] duration]))));
				break;
			case AVPlayerItemStatusFailed:
				NSLog(@"AVPlayerItemStatusFailed");
				_connectionResult(nil);
				break;
			case AVPlayerItemStatusUnknown:
				break;
		}
	}
}

- (void)setClip:(NSNumber*)start end:(NSNumber*)end {
	// TODO
}

- (void)play {
	// TODO: dynamically adjust the lag.
	//int lag = 6;
	//int start = [self getCurrentPosition];
	[_player play];
	[self setPlaybackState:playing];
	// TODO: convert this Android code to iOS
	/* if (endDetector != null) { */
	/* 	handler.removeCallbacks(endDetector); */
	/* } */
	/* if (untilPosition != null) { */
	/* 	final int duration = Math.max(0, untilPosition - start - lag); */
	/* 	handler.postDelayed(new Runnable() { */
	/* 		@Override */
	/* 		public void run() { */
	/* 			final int position = getCurrentPosition(); */
	/* 			if (position > untilPosition - 20) { */
	/* 				pause(); */
	/* 			} else { */
	/* 				final int duration = Math.max(0, untilPosition - position - lag); */
	/* 				handler.postDelayed(this, duration); */
	/* 			} */
	/* 		} */
	/* 	}, duration); */
	/* } */
}

- (void)pause {
	[_player pause];
	[self setPlaybackState:paused];
}

- (void)stop {
	[_player pause];
	[_player seekToTime:CMTimeMake(0, 1000)
	  completionHandler:^(BOOL finished) {
		  [self setPlaybackState:stopped];
	  }];
}

- (void)complete {
	[_player pause];
	[_player seekToTime:CMTimeMake(0, 1000)
	  completionHandler:^(BOOL finished) {
		  [self setPlaybackState:completed];
	  }];
}

- (void)setVolume:(float)volume {
	[_player setVolume:volume];
}

- (void)setSpeed:(float)speed {
	if (speed == 1.0
			|| speed < 1.0 && _player.currentItem.canPlaySlowForward
			|| speed > 1.0 && _player.currentItem.canPlayFastForward) {
		_player.rate = speed;
	}
}

- (void)seek:(int)position result:(FlutterResult)result {
	_stateBeforeSeek = _state;
	_seekPos = position;
	NSLog(@"seek. enter buffering");
	[self setPlaybackState:buffering];
	[_player seekToTime:CMTimeMake(position, 1000)
	  completionHandler:^(BOOL finished) {
		  NSLog(@"seek completed");
		  [self onSeekCompletion:result];
	  }];
}

- (void)onSeekCompletion:(FlutterResult)result {
	_seekPos = -1;
	[self setPlaybackState:_stateBeforeSeek];
	_stateBeforeSeek = none;
	result(nil);
}

- (void)dispose {
	if (_state != none) {
		[self stop];
		[self setPlaybackState:none];
	}
}

@end
