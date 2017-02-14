//
//  MTBBarcodeScanner.m
//  MTBBarcodeScannerExample
//
//  Created by Mike Buss on 2/8/14.
//
//

#import <QuartzCore/QuartzCore.h>
#import "MTBBarcodeScanner.h"

CGFloat const kFocalPointOfInterestX = 0.5;
CGFloat const kFocalPointOfInterestY = 0.5;

static NSString *kErrorDomain = @"MTBBarcodeScannerError";

// Error Codes
static const NSInteger kErrorCodeStillImageCaptureInProgress = 1000;
static const NSInteger kErrorCodeSessionIsClosed = 1001;
static const NSInteger kErrorCodeNotScanning = 1002;
static const NSInteger kErrorCodeSessionAlreadyActive = 1003;

@interface MTBBarcodeScanner () <AVCaptureMetadataOutputObjectsDelegate>

/*!
 @property privateSessionQueue
 @abstract
 Starting or stopping the capture session should only be done on this queue.
 */
@property (strong) dispatch_queue_t privateSessionQueue;

/*!
 @property session
 @abstract
 The capture session used for scanning barcodes.
 */
@property (nonatomic, strong) AVCaptureSession *session;

/*!
 @property captureDevice
 @abstract
 Represents the physical device that is used for scanning barcodes.
 */
@property (nonatomic, strong) AVCaptureDevice *captureDevice;

/*!
 @property capturePreviewLayer
 @abstract
 The layer used to view the camera input. This layer is added to the
 previewView when scanning starts.
 */
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *capturePreviewLayer;

/*!
 @property currentCaptureDeviceInput
 @abstract
 The current capture device input for capturing video. This is used
 to reset the camera to its initial properties when scanning stops.
 */
@property (nonatomic, strong) AVCaptureDeviceInput *currentCaptureDeviceInput;

/*
 @property captureDeviceOnput
 @abstract
 The capture device output for capturing video.
 */
@property (nonatomic, strong) AVCaptureMetadataOutput *captureOutput;

/*!
 @property metaDataObjectTypes
 @abstract
 The MetaDataObjectTypes to look for in the scanning session.
 
 @discussion
 Only objects with a MetaDataObjectType found in this array will be
 reported to the result block.
 */
@property (nonatomic, copy) NSArray<NSString *> *metaDataObjectTypes;

/*!
 @property previewView
 @abstract
 The view used to preview the camera input.
 
 @discussion
 The AVCaptureVideoPreviewLayer is added to this view to preview the
 camera input when scanning starts. When scanning stops, the layer is
 removed.
 */
@property (nonatomic, weak) UIView *previewView;

/*!
 @property initialAutoFocusRangeRestriction
 @abstract
 The auto focus range restriction the AVCaptureDevice was initially configured for when scanning started.
 
 @discussion
 When startScanning is called, the auto focus range restriction of the default AVCaptureDevice
 is stored. When stopScanning is called, the AVCaptureDevice is reset to the initial range restriction
 to prevent a bug in the AVFoundation framework.
 */
@property (nonatomic, assign) AVCaptureAutoFocusRangeRestriction initialAutoFocusRangeRestriction;

/*!
 @property initialFocusPoint
 @abstract
 The focus point the AVCaptureDevice was initially configured for when scanning started.
 
 @discussion
 When startScanning is called, the focus point of the default AVCaptureDevice
 is stored. When stopScanning is called, the AVCaptureDevice is reset to the initial focal point
 to prevent a bug in the AVFoundation framework.
 */
@property (nonatomic, assign) CGPoint initialFocusPoint;

/*!
 @property stillImageOutput
 @abstract
 Used for still image capture
 */
@property (nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;

/*!
 @property gestureRecognizer
 @abstract
 If allowTapToFocus is set to YES, this gesture recognizer is added to the `previewView`
 when scanning starts. When the user taps the view, the `focusPointOfInterest` will change
 to the location the user tapped.
 */
@property (nonatomic, strong) UITapGestureRecognizer *gestureRecognizer;

@end

@implementation MTBBarcodeScanner

#pragma mark - Lifecycle

- (instancetype)init {
    NSAssert(NO, @"MTBBarcodeScanner init is not supported. Please use initWithPreviewView: \
             or initWithMetadataObjectTypes:previewView: to instantiate a MTBBarcodeScanner");
    return nil;
}

- (instancetype)initWithPreviewView:(UIView *)previewView {
    return [self initWithMetadataObjectTypes:[self defaultMetaDataObjectTypes] previewView:previewView];
}

- (instancetype)initWithMetadataObjectTypes:(NSArray<NSString *> *)metaDataObjectTypes previewView:(UIView *)previewView {
    NSParameterAssert(metaDataObjectTypes);
    NSAssert(metaDataObjectTypes.count > 0,
             @"Must initialize MTBBarcodeScanner with at least one metaDataObjectTypes value.");
    
    self = [super init];
    if (self) {
        // Library does not support scanning for faces
        NSAssert(!([metaDataObjectTypes indexOfObject:AVMetadataObjectTypeFace] != NSNotFound),
                 @"The type %@ is not supported by MTBBarcodeScanner.", AVMetadataObjectTypeFace);
        
        _metaDataObjectTypes = metaDataObjectTypes;
        _previewView = previewView;
        _allowTapToFocus = YES;
        [self setupSessionQueue];
        [self addRotationObserver];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Scanning

+ (BOOL)cameraIsPresent {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo] != nil;
}

+ (BOOL)scanningIsProhibited {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            return YES;
            break;
            
        default:
            return NO;
            break;
    }
}

+ (void)requestCameraPermissionWithSuccess:(void (^)(BOOL success))successBlock {
    if (![self cameraIsPresent]) {
        successBlock(NO);
        return;
    }
    
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
        case AVAuthorizationStatusAuthorized:
            successBlock(YES);
            break;
            
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            successBlock(NO);
            break;
            
        case AVAuthorizationStatusNotDetermined:
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                                         
                                         dispatch_async(dispatch_get_main_queue(), ^{
                                             successBlock(granted);
                                         });
                                         
                                     }];
            break;
    }
}

- (BOOL)startScanningWithError:(NSError **)error {
    return [self startScanningWithResultBlock:self.resultBlock error:error];
}

- (BOOL)startScanningWithResultBlock:(void (^)(NSArray<AVMetadataMachineReadableCodeObject *> *codes))resultBlock error:(NSError **)error {
    NSAssert([MTBBarcodeScanner cameraIsPresent], @"Attempted to start scanning on a device with no camera. Check requestCameraPermissionWithSuccess: method before calling startScanningWithResultBlock:");
    NSAssert(![MTBBarcodeScanner scanningIsProhibited], @"Scanning is prohibited on this device. \
             Check requestCameraPermissionWithSuccess: method before calling startScanningWithResultBlock:");
    NSAssert(resultBlock, @"startScanningWithResultBlock: requires a non-nil resultBlock.");

    if (self.session) {
        if (error) {
            *error = [NSError errorWithDomain:kErrorDomain
                                         code:kErrorCodeSessionAlreadyActive
                                     userInfo:@{NSLocalizedDescriptionKey : @"Do not start scanning while another session is in use."}];
        }

        return NO;
    }

    // Configure the session
    self.captureDevice = [self newCaptureDeviceWithCamera:self.camera];
    AVCaptureSession *session = [self newSessionWithCaptureDevice:self.captureDevice error:error];

    if (!session) {
        // we rely on newSessionWithCaptureDevice:error: to populate the error
        return NO;
    }

    self.session = session;

    // Configure the rect of interest
    self.captureOutput.rectOfInterest = [self rectOfInterestFromScanRect:self.scanRect];

    // Configure the preview layer
    self.capturePreviewLayer.cornerRadius = self.previewView.layer.cornerRadius;
    [self.previewView.layer insertSublayer:self.capturePreviewLayer atIndex:0]; // Insert below all other views
    [self refreshVideoOrientation];

    // Configure 'tap to focus' functionality
    [self configureTapToFocus];

    self.resultBlock = resultBlock;

    dispatch_async(self.privateSessionQueue, ^{
        // Start the session after all configurations:
        // Must be dispatched as it is blocking
        [self.session startRunning];

        if (self.didStartScanningBlock) {
            // Call that block now that we've started scanning:
            // Dispatch back to main
            dispatch_async(dispatch_get_main_queue(), ^{
                self.didStartScanningBlock();
            });
        }
    });

    return YES;
}

- (void)stopScanning {
    if (!self.session) {
        return;
    }

    // Turn the torch off
    self.torchMode = MTBTorchModeOff;

    // Remove the preview layer
    [self.capturePreviewLayer removeFromSuperlayer];

    // Stop recognizing taps for the 'Tap to Focus' feature
    [self stopRecognizingTaps];

    // When we're finished scanning, reset the settings for the camera
    // to their original states
    [self removeDeviceInput];

    for (AVCaptureOutput *output in self.session.outputs) {
        [self.session removeOutput:output];
    }

    self.resultBlock = nil;
    self.capturePreviewLayer = nil;

    AVCaptureSession *session = self.session;
    self.session = nil;

    dispatch_async(self.privateSessionQueue, ^{
        // Must be dispatched as it is blocking
        [session stopRunning];
    });
}

- (BOOL)isScanning {
    return [self.session isRunning];
}

- (void)flipCamera {
    [self flipCameraWithError:nil];
}

- (BOOL)flipCameraWithError:(NSError **)error {
    if (!self.isScanning) {
        if (error) {
            *error = [NSError errorWithDomain:kErrorDomain
                                         code:kErrorCodeNotScanning
                                     userInfo:@{NSLocalizedDescriptionKey : @"Camera cannot be flipped when isScanning is NO"}];
        }

        return NO;
    }

    if (self.camera == MTBCameraFront) {
        return [self setCamera:MTBCameraBack error:error];
    } else {
        return [self setCamera:MTBCameraFront error:error];
    }
}

#pragma mark - Tap to Focus

- (void)configureTapToFocus {
    if (self.allowTapToFocus) {
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusTapped:)];
        [self.previewView addGestureRecognizer:tapGesture];
        self.gestureRecognizer = tapGesture;
    }
}

- (void)focusTapped:(UITapGestureRecognizer *)tapGesture {
    CGPoint tapPoint = [self.gestureRecognizer locationInView:self.gestureRecognizer.view];
    CGPoint devicePoint = [self.capturePreviewLayer captureDevicePointOfInterestForPoint:tapPoint];
    
    AVCaptureDevice *device = self.captureDevice;
    NSError *error = nil;
    
    if ([device lockForConfiguration:&error]) {
        if (device.isFocusPointOfInterestSupported &&
            [device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            
            device.focusPointOfInterest = devicePoint;
            device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        }
        [device unlockForConfiguration];
    }
    
    if (self.didTapToFocusBlock) {
        self.didTapToFocusBlock(tapPoint);
    }
}

- (void)stopRecognizingTaps {
    if (self.gestureRecognizer) {
        [self.previewView removeGestureRecognizer:self.gestureRecognizer];
    }
}

#pragma mark - AVCaptureMetadataOutputObjects Delegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    if (!self.resultBlock) return;
    
    NSMutableArray *codes = [[NSMutableArray alloc] init];
    
    for (AVMetadataObject *metaData in metadataObjects) {
        AVMetadataMachineReadableCodeObject *barCodeObject = (AVMetadataMachineReadableCodeObject *)[self.capturePreviewLayer transformedMetadataObjectForMetadataObject:(AVMetadataMachineReadableCodeObject *)metaData];
        if (barCodeObject) {
            [codes addObject:barCodeObject];
        }
    }
    
    self.resultBlock(codes);
}

#pragma mark - Rotation

- (void)handleDeviceOrientationDidChangeNotification:(NSNotification *)notification {
    [self refreshVideoOrientation];
}

- (void)refreshVideoOrientation {
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    self.capturePreviewLayer.frame = self.previewView.bounds;
    if ([self.capturePreviewLayer.connection isVideoOrientationSupported]) {
        self.capturePreviewLayer.connection.videoOrientation = [self captureOrientationForInterfaceOrientation:orientation];
    }
}

- (AVCaptureVideoOrientation)captureOrientationForInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    switch (interfaceOrientation) {
        case UIInterfaceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
        case UIInterfaceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
        case UIInterfaceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeRight;
        default:
            return AVCaptureVideoOrientationPortrait;
    }
}

#pragma mark - Session Configuration

- (AVCaptureSession *)newSessionWithCaptureDevice:(AVCaptureDevice *)captureDevice error:(NSError **)error {
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:error];

    if (!input) {
        // we rely on deviceInputWithDevice:error: to populate the error
        return nil;
    }

    AVCaptureSession *newSession = [[AVCaptureSession alloc] init];
    [self setDeviceInput:input session:newSession];

    // Set an optimized preset for barcode scanning
    [newSession setSessionPreset:AVCaptureSessionPresetHigh];

    self.captureOutput = [[AVCaptureMetadataOutput alloc] init];
    [self.captureOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];

    [newSession addOutput:self.captureOutput];
    self.captureOutput.metadataObjectTypes = self.metaDataObjectTypes;

    // Still image capture configuration
    self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
    self.stillImageOutput.outputSettings = @{AVVideoCodecKey: AVVideoCodecJPEG};

    if ([self.stillImageOutput isStillImageStabilizationSupported]) {
        self.stillImageOutput.automaticallyEnablesStillImageStabilizationWhenAvailable = YES;
    }

    if ([self.stillImageOutput respondsToSelector:@selector(isHighResolutionStillImageOutputEnabled)]) {
        self.stillImageOutput.highResolutionStillImageOutputEnabled = YES;
    }
    [newSession addOutput:self.stillImageOutput];

    self.captureOutput.rectOfInterest = [self rectOfInterestFromScanRect:self.scanRect];

    self.capturePreviewLayer = [AVCaptureVideoPreviewLayer layerWithSession:newSession];
    self.capturePreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.capturePreviewLayer.frame = self.previewView.bounds;

    [newSession commitConfiguration];

    return newSession;
}

- (AVCaptureDevice *)newCaptureDeviceWithCamera:(MTBCamera)camera {
    AVCaptureDevice *newCaptureDevice = nil;
    
    NSArray *videoDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevicePosition position = [self devicePositionForCamera:camera];
    for (AVCaptureDevice *device in videoDevices) {
        if (device.position == position) {
            newCaptureDevice = device;
            break;
        }
    }
    
    // If the front camera is not available, use the back camera
    if (!newCaptureDevice) {
        newCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    // Using AVCaptureFocusModeContinuousAutoFocus helps improve scan times
    NSError *error = nil;
    if ([newCaptureDevice lockForConfiguration:&error]) {
        if ([newCaptureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            newCaptureDevice.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        }
        [newCaptureDevice unlockForConfiguration];
    }
    
    return newCaptureDevice;
}

- (AVCaptureDevicePosition)devicePositionForCamera:(MTBCamera)camera {
    switch (camera) {
        case MTBCameraFront:
            return AVCaptureDevicePositionFront;
        case MTBCameraBack:
            return AVCaptureDevicePositionBack;
        default:
            return AVCaptureDevicePositionUnspecified;
            break;
    }
}

#pragma mark - Default Values

- (NSArray<NSString *> *)defaultMetaDataObjectTypes {
    NSMutableArray *types = [@[AVMetadataObjectTypeQRCode,
                               AVMetadataObjectTypeUPCECode,
                               AVMetadataObjectTypeCode39Code,
                               AVMetadataObjectTypeCode39Mod43Code,
                               AVMetadataObjectTypeEAN13Code,
                               AVMetadataObjectTypeEAN8Code,
                               AVMetadataObjectTypeCode93Code,
                               AVMetadataObjectTypeCode128Code,
                               AVMetadataObjectTypePDF417Code,
                               AVMetadataObjectTypeAztecCode] mutableCopy];
    
    if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_7_1) {
        [types addObjectsFromArray:@[AVMetadataObjectTypeInterleaved2of5Code,
                                     AVMetadataObjectTypeITF14Code,
                                     AVMetadataObjectTypeDataMatrixCode
                                     ]];
    }
    
    return [types copy];
}

#pragma mark - Helper Methods

- (void)addRotationObserver {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDeviceOrientationDidChangeNotification:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
}

- (void)setupSessionQueue {
    NSAssert(self.privateSessionQueue == NULL, @"Queue should only be set up once");

    if (self.privateSessionQueue) {
        return;
    }

    self.privateSessionQueue = dispatch_queue_create("com.mikebuss.MTBBarcodeScanner.captureSession", DISPATCH_QUEUE_SERIAL);
}

- (void)setDeviceInput:(AVCaptureDeviceInput *)deviceInput session:(AVCaptureSession *)session {
    if (deviceInput == nil) {
        // Nil device inputs cannot be added to instances of AVCaptureSession
        return;
    }
    
    [self removeDeviceInput];
    
    self.currentCaptureDeviceInput = deviceInput;
    
    if ([deviceInput.device lockForConfiguration:nil] == YES) {
        
        // Prioritize the focus on objects near to the device
        if ([deviceInput.device respondsToSelector:@selector(isAutoFocusRangeRestrictionSupported)] &&
            deviceInput.device.isAutoFocusRangeRestrictionSupported) {
            
            self.initialAutoFocusRangeRestriction = deviceInput.device.autoFocusRangeRestriction;
            deviceInput.device.autoFocusRangeRestriction = AVCaptureAutoFocusRangeRestrictionNear;
        }
        
        // Focus on the center of the image
        if ([deviceInput.device respondsToSelector:@selector(isFocusPointOfInterestSupported)] &&
            deviceInput.device.isFocusPointOfInterestSupported) {
            
            self.initialFocusPoint = deviceInput.device.focusPointOfInterest;
            deviceInput.device.focusPointOfInterest = CGPointMake(kFocalPointOfInterestX, kFocalPointOfInterestY);
        }
        
        [self updateTorchModeForCurrentSettings];
        
        [deviceInput.device unlockForConfiguration];
    }
    
    [session addInput:deviceInput];
}

- (void)removeDeviceInput {
    AVCaptureDeviceInput *deviceInput = self.currentCaptureDeviceInput;
    if (deviceInput == nil) {
        // No need to remove the device input if it was never set
        return;
    }
    
    // Restore focus settings to the previously saved state
    if ([deviceInput.device lockForConfiguration:nil] == YES) {
        if ([deviceInput.device respondsToSelector:@selector(isAutoFocusRangeRestrictionSupported)] &&
            deviceInput.device.isAutoFocusRangeRestrictionSupported) {
            deviceInput.device.autoFocusRangeRestriction = self.initialAutoFocusRangeRestriction;
        }
        
        if ([deviceInput.device respondsToSelector:@selector(isFocusPointOfInterestSupported)] &&
            deviceInput.device.isFocusPointOfInterestSupported) {
            deviceInput.device.focusPointOfInterest = self.initialFocusPoint;
        }
        
        [deviceInput.device unlockForConfiguration];
    }
    
    [self.session removeInput:deviceInput];
    self.currentCaptureDeviceInput = nil;
}

#pragma mark - Torch Control

- (void)setTorchMode:(MTBTorchMode)torchMode {
    _torchMode = torchMode;
    [self updateTorchModeForCurrentSettings];
}

- (void)toggleTorch {
    if (self.torchMode == MTBTorchModeAuto || self.torchMode == MTBTorchModeOff) {
        self.torchMode = MTBTorchModeOn;
    } else {
        self.torchMode = MTBTorchModeOff;
    }
}

- (void)updateTorchModeForCurrentSettings {
    AVCaptureDevice *backCamera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if ([backCamera isTorchAvailable] && [backCamera isTorchModeSupported:AVCaptureTorchModeOn]) {
        
        BOOL success = [backCamera lockForConfiguration:nil];
        if (success) {
            
            AVCaptureTorchMode mode = [self avTorchModeForMTBTorchMode:self.torchMode];
            
            [backCamera setTorchMode:mode];
            [backCamera unlockForConfiguration];
            
        }
    }
}

- (BOOL)hasTorch {
    AVCaptureDevice *captureDevice = [self newCaptureDeviceWithCamera:self.camera];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
    return input.device.hasTorch;
}

- (AVCaptureTorchMode)avTorchModeForMTBTorchMode:(MTBTorchMode)torchMode {
    AVCaptureTorchMode mode = AVCaptureTorchModeOff;
    
    if (torchMode == MTBTorchModeOn) {
        mode = AVCaptureTorchModeOn;
    } else if (torchMode == MTBTorchModeAuto) {
        mode = AVCaptureTorchModeAuto;
    }
    
    return mode;
}

#pragma mark - Capture

- (void)freezeCapture {
    self.capturePreviewLayer.connection.enabled = NO;

    dispatch_async(self.privateSessionQueue, ^{
        [self.session stopRunning];
    });
}

- (void)unfreezeCapture {
    if (!self.session) {
        return;
    }

    self.capturePreviewLayer.connection.enabled = YES;
    
    if (!self.session.isRunning) {
        [self setDeviceInput:self.currentCaptureDeviceInput session:self.session];

        dispatch_async(self.privateSessionQueue, ^{
            [self.session startRunning];
        });
    }
}


- (void)captureStillImage:(void (^)(UIImage *image, NSError *error))captureBlock {
    if ([self isCapturingStillImage]) {
        if (captureBlock) {
            NSError *error = [NSError errorWithDomain:kErrorDomain
                                                 code:kErrorCodeStillImageCaptureInProgress
                                             userInfo:@{NSLocalizedDescriptionKey : @"Still image capture is already in progress. Check with isCapturingStillImage"}];
            captureBlock(nil, error);
        }
        return;
    }
    
    AVCaptureConnection *stillConnection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    
    if (stillConnection == nil) {
        if (captureBlock) {
            NSError *error = [NSError errorWithDomain:kErrorDomain
                                                 code:kErrorCodeSessionIsClosed
                                             userInfo:@{NSLocalizedDescriptionKey : @"AVCaptureConnection is closed"}];
            captureBlock(nil, error);
        }
        return;
    }
    
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:stillConnection
                                                       completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
                                                           if (error) {
                                                               captureBlock(nil, error);
                                                               return;
                                                           }
                                                           
                                                           NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                                                           UIImage *image = [UIImage imageWithData:jpegData];
                                                           if (captureBlock) {
                                                               captureBlock(image, nil);
                                                           }
                                                           
                                                       }];
    
}

- (BOOL)isCapturingStillImage {
    return self.stillImageOutput.isCapturingStillImage;
}

#pragma mark - Setters

- (void)setCamera:(MTBCamera)camera {
    [self setCamera:camera error:nil];
}

- (BOOL)setCamera:(MTBCamera)camera error:(NSError **)error {
    if (camera == _camera) {
        return YES;
    }

    if (!self.isScanning) {
        if (error) {
            *error = [NSError errorWithDomain:kErrorDomain
                                         code:kErrorCodeNotScanning
                                     userInfo:@{NSLocalizedDescriptionKey : @"Camera cannot be set when isScanning is NO"}];
        }

        return NO;
    }

    AVCaptureDevice *captureDevice = [self newCaptureDeviceWithCamera:camera];
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:error];

    if (!input) {
        // we rely on deviceInputWithDevice:error to populate the error in this case
        return NO;
    }

    [self setDeviceInput:input session:self.session];
    _camera = camera;

    return YES;
}

- (void)setScanRect:(CGRect)scanRect {
    NSAssert(!CGRectIsEmpty(scanRect), @"Unable to set an empty rectangle as the scanRect of MTBBarcodeScanner");
    
    [self refreshVideoOrientation];
    
    _scanRect = scanRect;
    self.captureOutput.rectOfInterest = [self.capturePreviewLayer metadataOutputRectOfInterestForRect:_scanRect];
}

#pragma mark - Getters

- (CALayer *)previewLayer {
    return self.capturePreviewLayer;
}

#pragma mark - Helper Methods

- (CGRect)rectOfInterestFromScanRect:(CGRect)scanRect {
    CGRect rect = CGRectZero;
    if (!CGRectIsEmpty(self.scanRect)) {
        rect = [self.capturePreviewLayer metadataOutputRectOfInterestForRect:self.scanRect];
    } else {
        rect = CGRectMake(0, 0, 1, 1); // Default rectOfInterest for AVCaptureMetadataOutput
    }
    return rect;
}

@end
