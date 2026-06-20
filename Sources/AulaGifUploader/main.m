#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface KeyboardPreset : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic) NSUInteger recommendedFrames;
@end

@implementation KeyboardPreset
@end

@interface ImageInfo : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic) BOOL animated;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) BOOL readable;
@end

@implementation ImageInfo
@end

static KeyboardPreset *Preset(NSString *name, NSUInteger width, NSUInteger height, NSUInteger frames) {
    KeyboardPreset *preset = [KeyboardPreset new];
    preset.name = name;
    preset.width = width;
    preset.height = height;
    preset.recommendedFrames = frames;
    return preset;
}

static NSArray<KeyboardPreset *> *KeyboardPresets(void) {
    static NSArray<KeyboardPreset *> *presets;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        presets = @[
            Preset(@"AULA F108Pro", 240, 135, 32),
            Preset(@"AULA F75 Max", 128, 128, 120)
        ];
    });
    return presets;
}

static NSString *HumanSize(unsigned long long bytes) {
    double value = (double)bytes;
    NSArray<NSString *> *units = @[@"B", @"KB", @"MB", @"GB"];
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) {
        value /= 1024.0;
        unit++;
    }
    return [NSString stringWithFormat:unit == 0 ? @"%.0f %@" : @"%.1f %@", value, units[unit]];
}

static ImageInfo *InspectImage(NSURL *url) {
    ImageInfo *info = [ImageInfo new];
    info.path = url.path;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    info.bytes = attrs.fileSize;

    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        info.status = @"Unsupported image file.";
        info.readable = NO;
        return info;
    }

    size_t frameCount = CGImageSourceGetCount(source);
    info.frames = MAX((NSUInteger)frameCount, 1);
    info.animated = info.frames > 1;

    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    info.width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    info.height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    CFRelease(source);

    if (info.width == 0 || info.height == 0) {
        info.status = @"Could not read image dimensions.";
        info.readable = NO;
        return info;
    }

    info.status = @"Ready.";
    info.readable = YES;
    return info;
}

@interface DropView : NSView
@property(nonatomic, copy) void (^fileHandler)(NSURL *url);
@end

@implementation DropView
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [NSColor separatorColor].CGColor;
        self.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    self.layer.borderColor = [NSColor controlAccentColor].CGColor;
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.layer.borderColor = [NSColor separatorColor].CGColor;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.layer.borderColor = [NSColor separatorColor].CGColor;
    NSURL *url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
    if (url && self.fileHandler) {
        self.fileHandler(url);
        return YES;
    }
    return NO;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSPopUpButton *modelPopup;
@property(nonatomic, strong) NSTextField *widthField;
@property(nonatomic, strong) NSTextField *heightField;
@property(nonatomic, strong) NSTextField *frameLimitField;
@property(nonatomic, strong) NSTextField *targetLabel;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *detailsLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, strong) NSButton *uploadButton;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) ImageInfo *selectedInfo;
@property(nonatomic, strong) NSTask *uploadTask;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildWindow];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 420)
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = @"AULA GIF Uploader";
    self.window.releasedWhenClosed = NO;
    [self.window center];

    NSView *content = self.window.contentView;

    [content addSubview:[self label:@"Keyboard" frame:NSMakeRect(24, 366, 90, 18) size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor alignment:NSTextAlignmentLeft]];
    self.modelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 336, 180, 28) pullsDown:NO];
    for (KeyboardPreset *preset in KeyboardPresets()) {
        [self.modelPopup addItemWithTitle:preset.name];
    }
    self.modelPopup.target = self;
    self.modelPopup.action = @selector(modelChanged:);
    [content addSubview:self.modelPopup];

    [content addSubview:[self label:@"Width" frame:NSMakeRect(224, 366, 70, 18) size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor alignment:NSTextAlignmentLeft]];
    self.widthField = [self numberField:NSMakeRect(224, 336, 70, 28)];
    [content addSubview:self.widthField];

    [content addSubview:[self label:@"Height" frame:NSMakeRect(310, 366, 70, 18) size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor alignment:NSTextAlignmentLeft]];
    self.heightField = [self numberField:NSMakeRect(310, 336, 70, 28)];
    [content addSubview:self.heightField];

    [content addSubview:[self label:@"Frames" frame:NSMakeRect(396, 366, 80, 18) size:12 weight:NSFontWeightMedium color:NSColor.secondaryLabelColor alignment:NSTextAlignmentLeft]];
    self.frameLimitField = [self numberField:NSMakeRect(396, 336, 80, 28)];
    [content addSubview:self.frameLimitField];

    self.targetLabel = [self label:@"" frame:NSMakeRect(24, 306, 472, 18) size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor alignment:NSTextAlignmentLeft];
    [content addSubview:self.targetLabel];

    DropView *drop = [[DropView alloc] initWithFrame:NSMakeRect(24, 126, 472, 166)];
    __weak typeof(self) weakSelf = self;
    drop.fileHandler = ^(NSURL *url) {
        [weakSelf selectURL:url];
    };
    [content addSubview:drop];

    self.titleLabel = [self label:@"Drop image/GIF here" frame:NSMakeRect(48, 222, 424, 26) size:18 weight:NSFontWeightSemibold color:NSColor.labelColor alignment:NSTextAlignmentCenter];
    [content addSubview:self.titleLabel];

    self.detailsLabel = [self label:@"Choose a keyboard model, then upload an image or GIF." frame:NSMakeRect(48, 176, 424, 42) size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor alignment:NSTextAlignmentCenter];
    self.detailsLabel.maximumNumberOfLines = 2;
    [content addSubview:self.detailsLabel];

    self.chooseButton = [NSButton buttonWithTitle:@"Choose Image/GIF" target:self action:@selector(chooseFile:)];
    self.chooseButton.frame = NSMakeRect(176, 138, 168, 30);
    self.chooseButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.chooseButton];

    self.statusLabel = [self label:@"Connect the AULA keyboard in wired USB mode before uploading." frame:NSMakeRect(24, 86, 472, 18) size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor alignment:NSTextAlignmentCenter];
    [content addSubview:self.statusLabel];

    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 62, 472, 12)];
    self.progress.minValue = 0;
    self.progress.maxValue = 100;
    self.progress.doubleValue = 0;
    self.progress.indeterminate = NO;
    [content addSubview:self.progress];

    self.uploadButton = [NSButton buttonWithTitle:@"Send to Keyboard" target:self action:@selector(upload:)];
    self.uploadButton.frame = NSMakeRect(184, 22, 152, 32);
    self.uploadButton.bezelStyle = NSBezelStyleRounded;
    self.uploadButton.enabled = NO;
    [content addSubview:self.uploadButton];

    [self applyPreset:KeyboardPresets().firstObject];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color alignment:(NSTextAlignment)alignment {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.alignment = alignment;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

- (NSTextField *)numberField:(NSRect)frame {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.delegate = self;
    field.alignment = NSTextAlignmentRight;
    field.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    return field;
}

- (KeyboardPreset *)selectedPreset {
    NSInteger index = self.modelPopup.indexOfSelectedItem;
    NSArray<KeyboardPreset *> *presets = KeyboardPresets();
    if (index < 0 || (NSUInteger)index >= presets.count) {
        return presets.firstObject;
    }
    return presets[(NSUInteger)index];
}

- (void)modelChanged:(id)sender {
    [self applyPreset:self.selectedPreset];
}

- (void)applyPreset:(KeyboardPreset *)preset {
    self.widthField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)preset.width];
    self.heightField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)preset.height];
    self.frameLimitField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)preset.recommendedFrames];
    [self refreshValidation];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self refreshValidation];
}

- (NSUInteger)integerFromField:(NSTextField *)field {
    NSInteger value = field.integerValue;
    return value > 0 ? (NSUInteger)value : 0;
}

- (NSUInteger)targetWidth {
    return [self integerFromField:self.widthField];
}

- (NSUInteger)targetHeight {
    return [self integerFromField:self.heightField];
}

- (NSUInteger)frameLimit {
    NSUInteger value = [self integerFromField:self.frameLimitField];
    return value > 255 ? 255 : value;
}

- (void)refreshValidation {
    KeyboardPreset *preset = self.selectedPreset;
    NSUInteger width = self.targetWidth;
    NSUInteger height = self.targetHeight;
    NSUInteger frameLimit = self.frameLimit;
    BOOL validTarget = width > 0 && height > 0 && frameLimit > 0;

    self.targetLabel.stringValue = [NSString stringWithFormat:@"%@ preset: %lu x %lu, recommended max %lu frames. Current target: %lu x %lu, sending up to %lu frame%@.",
        preset.name,
        (unsigned long)preset.width,
        (unsigned long)preset.height,
        (unsigned long)preset.recommendedFrames,
        (unsigned long)width,
        (unsigned long)height,
        (unsigned long)frameLimit,
        frameLimit == 1 ? @"" : @"s"
    ];

    if (!validTarget) {
        self.statusLabel.textColor = NSColor.systemRedColor;
        self.statusLabel.stringValue = @"Width, height, and frame limit must be positive numbers.";
        self.uploadButton.enabled = NO;
        return;
    }

    if (!self.selectedInfo) {
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
        self.statusLabel.stringValue = @"Connect the AULA keyboard in wired USB mode before uploading.";
        self.uploadButton.enabled = NO;
        return;
    }

    if (!self.selectedInfo.readable) {
        self.statusLabel.textColor = NSColor.systemRedColor;
        self.statusLabel.stringValue = self.selectedInfo.status ?: @"Unsupported image file.";
        self.uploadButton.enabled = NO;
        return;
    }

    NSUInteger sentFrames = MIN(self.selectedInfo.frames, frameLimit);
    BOOL willResize = self.selectedInfo.width != width || self.selectedInfo.height != height;
    BOOL willTrim = self.selectedInfo.frames > frameLimit;

    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    [notes addObject:willResize ? [NSString stringWithFormat:@"will fit to %lu x %lu", (unsigned long)width, (unsigned long)height] : @"size matches target"];
    [notes addObject:willTrim ? [NSString stringWithFormat:@"will trim %lu to %lu frames", (unsigned long)self.selectedInfo.frames, (unsigned long)sentFrames] : [NSString stringWithFormat:@"will send %lu frame%@", (unsigned long)sentFrames, sentFrames == 1 ? @"" : @"s"]];

    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Ready: %@.", [notes componentsJoinedByString:@", "]];
    self.uploadButton.enabled = YES;
}

- (void)chooseFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeGIF, UTTypePNG, UTTypeJPEG, UTTypeImage];
    if ([panel runModal] == NSModalResponseOK) {
        [self selectURL:panel.URL];
    }
}

- (void)selectURL:(NSURL *)url {
    ImageInfo *info = InspectImage(url);
    self.selectedInfo = info;
    self.progress.doubleValue = 0;

    NSString *name = url.lastPathComponent ?: @"Selected file";
    self.titleLabel.stringValue = name;
    self.detailsLabel.stringValue = [NSString stringWithFormat:@"%lu x %lu | %lu frame%@ | %@",
        (unsigned long)info.width,
        (unsigned long)info.height,
        (unsigned long)info.frames,
        info.frames == 1 ? @"" : @"s",
        HumanSize(info.bytes)
    ];
    [self refreshValidation];
}

- (void)setBusy:(BOOL)busy {
    self.modelPopup.enabled = !busy;
    self.widthField.enabled = !busy;
    self.heightField.enabled = !busy;
    self.frameLimitField.enabled = !busy;
    self.chooseButton.enabled = !busy;
    self.uploadButton.enabled = !busy && self.selectedInfo.readable && self.targetWidth > 0 && self.targetHeight > 0 && self.frameLimit > 0;
}

- (NSURL *)probeURL {
    return [[[NSBundle mainBundle] executableURL].URLByDeletingLastPathComponent URLByAppendingPathComponent:@"F75Probe"];
}

- (void)upload:(id)sender {
    if (!self.selectedInfo.readable || self.targetWidth == 0 || self.targetHeight == 0 || self.frameLimit == 0) {
        return;
    }

    NSURL *probe = [self probeURL];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:probe.path]) {
        [self fail:@"Bundled F75Probe helper is missing."];
        return;
    }

    self.progress.doubleValue = 1;
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = @"Uploading...";
    [self setBusy:YES];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = probe;
    task.currentDirectoryURL = probe.URLByDeletingLastPathComponent;
    task.arguments = @[
        @"--wired",
        @"--screen-upload-image", self.selectedInfo.path,
        @"--screen-width", [NSString stringWithFormat:@"%lu", (unsigned long)self.targetWidth],
        @"--screen-height", [NSString stringWithFormat:@"%lu", (unsigned long)self.targetHeight],
        @"--screen-max-frames", [NSString stringWithFormat:@"%lu", (unsigned long)self.frameLimit],
        @"--screen-fit", @"contain",
        @"--screen-pixel-format", @"rgb565le",
        @"--screen-pixel-layout", @"row",
        @"--screen-slot", @"1",
        @"--screen-chunk-ack",
        @"--screen-chunk-delay", @"0.005",
        @"--seconds", @"1"
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.uploadTask = task;

    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {
            return;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        [weakSelf parseProgress:text];
    };

    task.terminationHandler = ^(NSTask *finishedTask) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setBusy:NO];
            weakSelf.uploadTask = nil;
            if (finishedTask.terminationStatus == 0) {
                weakSelf.progress.doubleValue = 100;
                weakSelf.statusLabel.textColor = NSColor.systemGreenColor;
                weakSelf.statusLabel.stringValue = @"Complete!";
            } else {
                weakSelf.statusLabel.textColor = NSColor.systemRedColor;
                weakSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Upload failed (%d). Check wired USB mode and permissions.", finishedTask.terminationStatus];
            }
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self setBusy:NO];
        [self fail:error.localizedDescription ?: @"Could not start upload helper."];
    }
}

- (void)parseProgress:(NSString *)text {
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"chunk ([0-9]+)/([0-9]+)" options:0 error:nil];
    for (NSString *line in lines) {
        NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (match.numberOfRanges == 3) {
            NSInteger current = [[line substringWithRange:[match rangeAtIndex:1]] integerValue];
            NSInteger total = [[line substringWithRange:[match rangeAtIndex:2]] integerValue];
            if (total > 0) {
                double percent = MAX(1.0, MIN(99.0, ((double)current / (double)total) * 100.0));
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.progress.doubleValue = percent;
                    self.statusLabel.stringValue = [NSString stringWithFormat:@"Uploading... %ld/%ld", (long)current, (long)total];
                });
            }
        }
    }
}

- (void)fail:(NSString *)message {
    self.statusLabel.textColor = NSColor.systemRedColor;
    self.statusLabel.stringValue = message;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"AULA GIF Uploader";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
