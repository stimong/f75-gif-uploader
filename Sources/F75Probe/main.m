#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/usb/USBSpec.h>

typedef struct {
    int vendorID;
    int productID;
    int usagePage;
} DeviceMatch;

static const int kDongleVendorID = 0x05ac;
static const int kDongleProductID = 0x024f;
static const int kWiredVendorID = 0x0c45;
static const int kWiredProductID = 0x800a;

static const DeviceMatch kDongleMatches[] = {
    {0x05ac, 0x024f, 0xff59},
    {0x05ac, 0x024f, 0xff60},
};

static const DeviceMatch kWiredMatches[] = {
    {0x0c45, 0x800a, 0xff13},
    {0x0c45, 0x800a, 0xff68},
};

static const DeviceMatch kWiredControlMatches[] = {
    {0x0c45, 0x800a, 0xff13},
};

typedef struct {
    IOHIDDeviceRef device;
    char product[256];
    int usagePage;
    int usage;
    int inputSize;
    int outputSize;
    int featureSize;
    uint8_t *buffer;
    uint8_t lastReport[64];
    CFIndex lastReportLength;
    uint64_t reportCounter;
    bool suppressInputLog;
} DeviceMonitor;

typedef struct {
    IOUSBInterfaceInterface **interface;
    UInt8 outputPipe;
    UInt8 inputPipe;
    UInt8 interfaceNumber;
} USBPipeInterface;

typedef enum {
    ScreenFitContain,
    ScreenFitCover,
    ScreenFitStretch,
} ScreenFitMode;

typedef enum {
    ScreenPixelRGB565LE,
    ScreenPixelRGB565BE,
    ScreenPixelBGR565LE,
    ScreenPixelBGR565BE,
} ScreenPixelFormat;

typedef enum {
    ScreenLayoutRowMajor,
    ScreenLayoutFlipX,
    ScreenLayoutFlipY,
    ScreenLayoutRotate180,
    ScreenLayoutRowSnake,
    ScreenLayoutColumnMajor,
    ScreenLayoutColumnFlipX,
    ScreenLayoutColumnFlipY,
    ScreenLayoutTile8,
    ScreenLayoutTile16,
} ScreenPixelLayout;

static int intProperty(IOHIDDeviceRef device, CFStringRef key, int fallback) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return fallback;
    }
    int out = fallback;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &out);
    return out;
}

static void stringProperty(IOHIDDeviceRef device, CFStringRef key, char *buffer, size_t size, const char *fallback) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        if (CFStringGetCString((CFStringRef)value, buffer, size, kCFStringEncodingUTF8)) {
            return;
        }
    }
    strlcpy(buffer, fallback, size);
}

static CFMutableDictionaryRef matchingDictionary(int vendorID, int productID, int usagePage) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    int vendor = vendorID;
    int product = productID;
    int page = usagePage;
    CFNumberRef vendorRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
    CFNumberRef productRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
    CFNumberRef pageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);

    CFDictionarySetValue(dict, CFSTR(kIOHIDVendorIDKey), vendorRef);
    CFDictionarySetValue(dict, CFSTR(kIOHIDProductIDKey), productRef);
    if (usagePage >= 0) {
        CFDictionarySetValue(dict, CFSTR(kIOHIDDeviceUsagePageKey), pageRef);
    }

    CFRelease(vendorRef);
    CFRelease(productRef);
    CFRelease(pageRef);
    return dict;
}

static int registryIntProperty(io_service_t service, CFStringRef key, int fallback) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) {
        return fallback;
    }

    int out = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &out);
    }
    CFRelease(value);
    return out;
}

static const char *usbDirectionName(UInt8 direction) {
    if (direction == kUSBIn) {
        return "in";
    }
    if (direction == kUSBOut) {
        return "out";
    }
    return "unknown";
}

static const char *usbTransferTypeName(UInt8 transferType) {
    switch (transferType) {
        case kUSBControl:
            return "control";
        case kUSBIsoc:
            return "isochronous";
        case kUSBBulk:
            return "bulk";
        case kUSBInterrupt:
            return "interrupt";
        default:
            return "unknown";
    }
}

static bool openUSBPipeInterface(UInt8 interfaceNumber, bool seize, USBPipeInterface *pipeInterface) {
    memset(pipeInterface, 0, sizeof(*pipeInterface));
    pipeInterface->interfaceNumber = interfaceNumber;

    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostInterface");
    if (!match) {
        printf("Could not create IOUSBHostInterface matching dictionary.\n");
        fflush(stdout);
        return false;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (result != kIOReturnSuccess) {
        printf("USB interface %u match failed result=0x%08x.\n", interfaceNumber, result);
        fflush(stdout);
        return false;
    }

    io_service_t service = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    while ((candidate = IOIteratorNext(iterator))) {
        int vendorID = registryIntProperty(candidate, CFSTR(kUSBVendorID), -1);
        int productID = registryIntProperty(candidate, CFSTR(kUSBProductID), -1);
        int foundInterfaceNumber = registryIntProperty(candidate, CFSTR(kUSBInterfaceNumber), -1);
        if (vendorID == kWiredVendorID && productID == kWiredProductID && foundInterfaceNumber == interfaceNumber) {
            service = candidate;
            break;
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);
    if (!service) {
        printf("USB interface %u was not found.\n", interfaceNumber);
        fflush(stdout);
        return false;
    }

    int ownerKnown = registryIntProperty(service, CFSTR("bNumEndpoints"), -1);
    printf("Found USB interface %u with %d endpoint(s); opening%s.\n", interfaceNumber, ownerKnown, seize ? " by seizing" : "");
    fflush(stdout);

    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    result = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugIn,
        &score
    );
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || !plugIn) {
        printf("Could not create USB interface plugin result=0x%08x score=%d.\n", result, score);
        fflush(stdout);
        return false;
    }

    IOUSBInterfaceInterface **usbInterface = NULL;
    HRESULT queryResult = (*plugIn)->QueryInterface(
        plugIn,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942),
        (LPVOID *)&usbInterface
    );
    (*plugIn)->Release(plugIn);
    if (queryResult || !usbInterface) {
        printf("Could not query USB interface object result=0x%08x.\n", (unsigned int)queryResult);
        fflush(stdout);
        return false;
    }

    result = seize ? (*usbInterface)->USBInterfaceOpenSeize(usbInterface) : (*usbInterface)->USBInterfaceOpen(usbInterface);
    if (result != kIOReturnSuccess) {
        printf("USB interface %u open%s failed result=0x%08x.\n", interfaceNumber, seize ? " seize" : "", result);
        fflush(stdout);
        (*usbInterface)->Release(usbInterface);
        return false;
    }

    UInt8 actualInterfaceNumber = 0;
    (*usbInterface)->GetInterfaceNumber(usbInterface, &actualInterfaceNumber);
    UInt8 endpointCount = 0;
    result = (*usbInterface)->GetNumEndpoints(usbInterface, &endpointCount);
    if (result != kIOReturnSuccess) {
        printf("USB interface %u GetNumEndpoints failed result=0x%08x.\n", interfaceNumber, result);
        fflush(stdout);
        (*usbInterface)->USBInterfaceClose(usbInterface);
        (*usbInterface)->Release(usbInterface);
        return false;
    }

    for (UInt8 pipeRef = 1; pipeRef <= endpointCount; pipeRef++) {
        UInt8 direction = 0;
        UInt8 endpoint = 0;
        UInt8 transferType = 0;
        UInt16 maxPacketSize = 0;
        UInt8 interval = 0;
        result = (*usbInterface)->GetPipeProperties(
            usbInterface,
            pipeRef,
            &direction,
            &endpoint,
            &transferType,
            &maxPacketSize,
            &interval
        );
        if (result != kIOReturnSuccess) {
            printf("USB interface %u pipe %u properties failed result=0x%08x.\n", interfaceNumber, pipeRef, result);
            continue;
        }

        printf(
            "USB interface %u pipe %u endpoint=%u direction=%s type=%s maxPacket=%u interval=%u\n",
            actualInterfaceNumber,
            pipeRef,
            endpoint,
            usbDirectionName(direction),
            usbTransferTypeName(transferType),
            maxPacketSize,
            interval
        );
        if (direction == kUSBOut && transferType == kUSBInterrupt) {
            pipeInterface->outputPipe = pipeRef;
        } else if (direction == kUSBIn && transferType == kUSBInterrupt) {
            pipeInterface->inputPipe = pipeRef;
        }
    }
    fflush(stdout);

    if (!pipeInterface->outputPipe) {
        printf("USB interface %u has no interrupt OUT pipe.\n", interfaceNumber);
        fflush(stdout);
        (*usbInterface)->USBInterfaceClose(usbInterface);
        (*usbInterface)->Release(usbInterface);
        return false;
    }

    pipeInterface->interface = usbInterface;
    return true;
}

static void closeUSBPipeInterface(USBPipeInterface *pipeInterface) {
    if (!pipeInterface->interface) {
        return;
    }
    (*pipeInterface->interface)->USBInterfaceClose(pipeInterface->interface);
    (*pipeInterface->interface)->Release(pipeInterface->interface);
    memset(pipeInterface, 0, sizeof(*pipeInterface));
}

static void printHex(const uint8_t *bytes, CFIndex length) {
    for (CFIndex i = 0; i < length; i++) {
        printf("%02x%s", bytes[i], i + 1 == length ? "" : " ");
    }
}

static void appendMatches(CFMutableArrayRef matches, const DeviceMatch *deviceMatches, size_t count) {
    for (size_t i = 0; i < count; i++) {
        CFMutableDictionaryRef dict = matchingDictionary(
            deviceMatches[i].vendorID,
            deviceMatches[i].productID,
            deviceMatches[i].usagePage
        );
        CFArrayAppendValue(matches, dict);
        CFRelease(dict);
    }
}

static void inputCallback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t *report,
    CFIndex reportLength
) {
    (void)sender;
    DeviceMonitor *monitor = (DeviceMonitor *)context;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    CFIndex copyLength = reportLength < (CFIndex)sizeof(monitor->lastReport) ? reportLength : (CFIndex)sizeof(monitor->lastReport);
    memcpy(monitor->lastReport, report, (size_t)copyLength);
    monitor->lastReportLength = copyLength;
    monitor->reportCounter++;

    if (monitor->suppressInputLog) {
        return;
    }

    printf(
        "%s %s page=0x%04x type=%ld result=0x%08x reportID=%u len=%ld bytes=",
        timestamp.UTF8String,
        monitor->product,
        monitor->usagePage,
        (long)type,
        result,
        reportID,
        (long)reportLength
    );
    printHex(report, reportLength);
    if (monitor->usagePage == 0xff60 && reportLength >= 4 && report[0] == 0x20 && report[1] == 0x01 && report[3] > 0 && report[3] <= 100) {
        printf(" batteryPercent=%u", report[3]);
    }
    printf("\n");
    fflush(stdout);
}

static double secondsArgument(int argc, const char *argv[]) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--seconds") == 0) {
            double seconds = atof(argv[i + 1]);
            return seconds < 1.0 ? 1.0 : seconds;
        }
    }
    return 12.0;
}

static bool allInterfacesArgument(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--all") == 0) {
            return true;
        }
    }
    return false;
}

static bool hasArgument(int argc, const char *argv[], const char *name) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return true;
        }
    }
    return false;
}

static int intArgument(int argc, const char *argv[], const char *name, int fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return (int)strtol(argv[i + 1], NULL, 0);
        }
    }
    return fallback;
}

static double doubleArgument(int argc, const char *argv[], const char *name, double fallback) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return atof(argv[i + 1]);
        }
    }
    return fallback;
}

static const char *stringArgument(int argc, const char *argv[], const char *name) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return argv[i + 1];
        }
    }
    return NULL;
}

static ScreenFitMode screenFitArgument(int argc, const char *argv[]) {
    const char *value = stringArgument(argc, argv, "--screen-fit");
    if (!value || strcmp(value, "cover") == 0) {
        return ScreenFitCover;
    }
    if (strcmp(value, "stretch") == 0) {
        return ScreenFitStretch;
    }
    return ScreenFitContain;
}

static ScreenPixelFormat screenPixelFormatArgument(int argc, const char *argv[]) {
    const char *value = stringArgument(argc, argv, "--screen-pixel-format");
    if (!value || strcmp(value, "rgb565le") == 0) {
        return ScreenPixelRGB565LE;
    }
    if (strcmp(value, "rgb565be") == 0) {
        return ScreenPixelRGB565BE;
    }
    if (strcmp(value, "bgr565le") == 0) {
        return ScreenPixelBGR565LE;
    }
    if (strcmp(value, "bgr565be") == 0) {
        return ScreenPixelBGR565BE;
    }
    return ScreenPixelRGB565LE;
}

static ScreenPixelLayout screenPixelLayoutArgument(int argc, const char *argv[]) {
    const char *value = stringArgument(argc, argv, "--screen-pixel-layout");
    if (!value || strcmp(value, "row") == 0) {
        return ScreenLayoutRowMajor;
    }
    if (strcmp(value, "flip-x") == 0) {
        return ScreenLayoutFlipX;
    }
    if (strcmp(value, "flip-y") == 0) {
        return ScreenLayoutFlipY;
    }
    if (strcmp(value, "rotate-180") == 0) {
        return ScreenLayoutRotate180;
    }
    if (strcmp(value, "row-snake") == 0) {
        return ScreenLayoutRowSnake;
    }
    if (strcmp(value, "column") == 0) {
        return ScreenLayoutColumnMajor;
    }
    if (strcmp(value, "column-flip-x") == 0) {
        return ScreenLayoutColumnFlipX;
    }
    if (strcmp(value, "column-flip-y") == 0) {
        return ScreenLayoutColumnFlipY;
    }
    if (strcmp(value, "tile8") == 0) {
        return ScreenLayoutTile8;
    }
    if (strcmp(value, "tile16") == 0) {
        return ScreenLayoutTile16;
    }
    return ScreenLayoutRowMajor;
}

static const char *screenPixelLayoutName(ScreenPixelLayout layout) {
    switch (layout) {
        case ScreenLayoutFlipX:
            return "flip-x";
        case ScreenLayoutFlipY:
            return "flip-y";
        case ScreenLayoutRotate180:
            return "rotate-180";
        case ScreenLayoutRowSnake:
            return "row-snake";
        case ScreenLayoutColumnMajor:
            return "column";
        case ScreenLayoutColumnFlipX:
            return "column-flip-x";
        case ScreenLayoutColumnFlipY:
            return "column-flip-y";
        case ScreenLayoutTile8:
            return "tile8";
        case ScreenLayoutTile16:
            return "tile16";
        case ScreenLayoutRowMajor:
        default:
            return "row";
    }
}

static bool dongleArgument(int argc, const char *argv[]) {
    return hasArgument(argc, argv, "--dongle");
}

static bool wiredArgument(int argc, const char *argv[]) {
    return hasArgument(argc, argv, "--wired");
}

static int hexValue(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return 10 + c - 'a';
    }
    if (c >= 'A' && c <= 'F') {
        return 10 + c - 'A';
    }
    return -1;
}

static bool isHexSeparator(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' || c == ':' || c == '-' || c == '_';
}

static bool parseHexBytes(const char *text, uint8_t *bytes, size_t capacity, size_t *lengthOut, char *error, size_t errorSize) {
    size_t length = 0;
    int highNibble = -1;

    if (!text || !bytes || !lengthOut) {
        if (error && errorSize > 0) {
            snprintf(error, errorSize, "missing hex input");
        }
        return false;
    }

    for (size_t i = 0; text[i] != '\0'; i++) {
        if (text[i] == '0' && (text[i + 1] == 'x' || text[i + 1] == 'X') && highNibble < 0) {
            i++;
            continue;
        }

        int value = hexValue(text[i]);
        if (value >= 0) {
            if (highNibble < 0) {
                highNibble = value;
            } else {
                if (length >= capacity) {
                    if (error && errorSize > 0) {
                        snprintf(error, errorSize, "hex payload is larger than %zu bytes", capacity);
                    }
                    return false;
                }
                bytes[length++] = (uint8_t)((highNibble << 4) | value);
                highNibble = -1;
            }
            continue;
        }

        if (isHexSeparator(text[i])) {
            continue;
        }

        if (error && errorSize > 0) {
            snprintf(error, errorSize, "invalid hex character '%c'", text[i]);
        }
        return false;
    }

    if (highNibble >= 0) {
        if (error && errorSize > 0) {
            snprintf(error, errorSize, "odd number of hex digits");
        }
        return false;
    }

    if (length == 0) {
        if (error && errorSize > 0) {
            snprintf(error, errorSize, "no hex bytes parsed");
        }
        return false;
    }

    *lengthOut = length;
    return true;
}

static bool applyRawChecksum(uint8_t *bytes, size_t length, int checksumIndex, char *error, size_t errorSize) {
    if (!bytes || length == 0) {
        if (error && errorSize > 0) {
            snprintf(error, errorSize, "cannot checksum an empty payload");
        }
        return false;
    }

    size_t index = checksumIndex >= 0 ? (size_t)checksumIndex : length - 1;
    if (index >= length) {
        if (error && errorSize > 0) {
            snprintf(error, errorSize, "checksum index %zu is outside the %zu-byte payload", index, length);
        }
        return false;
    }

    bytes[index] = 0;
    uint8_t sum = 0;
    for (size_t i = 0; i < length; i++) {
        sum = (uint8_t)(sum + bytes[i]);
    }
    bytes[index] = sum;
    return true;
}

static void sendRawHexReports(
    DeviceMonitor *monitors,
    CFIndex count,
    int usagePage,
    IOHIDReportType reportType,
    const char *hex,
    bool checksum,
    int checksumIndex,
    bool padReport
) {
    if (!hex) {
        return;
    }

    const char *reportName = reportType == kIOHIDReportTypeFeature ? "feature" : "output";
    if (usagePage < 0) {
        printf("Raw %s send skipped: pass --send-page 0xff60 or another explicit usage page.\n", reportName);
        fflush(stdout);
        return;
    }

    uint8_t bytes[4096] = {0};
    size_t length = 0;
    char error[160] = {0};
    if (!parseHexBytes(hex, bytes, sizeof(bytes), &length, error, sizeof(error))) {
        printf("Raw %s send skipped: %s.\n", reportName, error);
        fflush(stdout);
        return;
    }

    if (checksum && !applyRawChecksum(bytes, length, checksumIndex, error, sizeof(error))) {
        printf("Raw %s send skipped: %s.\n", reportName, error);
        fflush(stdout);
        return;
    }

    bool sent = false;
    for (CFIndex i = 0; i < count; i++) {
        DeviceMonitor *monitor = &monitors[i];
        if (monitor->usagePage != usagePage) {
            continue;
        }

        int maxReportSize = reportType == kIOHIDReportTypeFeature ? monitor->featureSize : monitor->outputSize;
        if (maxReportSize <= 0) {
            printf("Raw %s send skipped for page=0x%04x: endpoint has no %s report size.\n", reportName, monitor->usagePage, reportName);
            fflush(stdout);
            continue;
        }

        CFIndex reportLength = (reportType == kIOHIDReportTypeFeature || padReport) ? maxReportSize : (CFIndex)length;
        if ((CFIndex)length > reportLength) {
            printf(
                "Raw %s send skipped for page=0x%04x: %zu bytes exceeds report length %ld.\n",
                reportName,
                monitor->usagePage,
                length,
                (long)reportLength
            );
            fflush(stdout);
            continue;
        }

        uint8_t *payload = calloc((size_t)reportLength, sizeof(uint8_t));
        if (!payload) {
            printf("Raw %s send skipped for page=0x%04x: allocation failed.\n", reportName, monitor->usagePage);
            fflush(stdout);
            continue;
        }
        memcpy(payload, bytes, length);

        IOReturn result = IOHIDDeviceSetReport(monitor->device, reportType, 0, payload, reportLength);
        printf(
            "Sent raw %s to page=0x%04x len=%ld sourceLen=%zu result=0x%08x bytes=",
            reportName,
            monitor->usagePage,
            (long)reportLength,
            length,
            result
        );
        printHex(payload, reportLength);
        printf("\n");
        fflush(stdout);
        free(payload);
        sent = true;
    }

    if (!sent) {
        printf("Raw %s send found no matched endpoint with usagePage=0x%04x.\n", reportName, usagePage);
        fflush(stdout);
    }
}

static bool buildWirelessRGBModeReport(int mode, uint8_t report[32]) {
    if (!report || mode < 0 || mode > 31) {
        return false;
    }

    memset(report, 0, 32);
    report[0] = 0x05;
    report[1] = 0x01;
    report[2] = 0x00;
    report[3] = (uint8_t)(mode + 0x1f);
    report[17] = 0xaa;
    report[18] = 0x55;

    char error[160] = {0};
    return applyRawChecksum(report, 32, 31, error, sizeof(error));
}

static bool buildWirelessRGBCommitReportVariant(uint8_t *report, size_t length, bool includeReportID) {
    if (!report || length < (includeReportID ? 33 : 32)) {
        return false;
    }

    memset(report, 0, length);
    size_t base = includeReportID ? 1 : 0;
    size_t checksumIndex = includeReportID ? 32 : 31;
    report[base] = 0x0f;

    char error[160] = {0};
    return applyRawChecksum(report, length, (int)checksumIndex, error, sizeof(error));
}

static bool buildWirelessRGBCommitReport(uint8_t report[32]) {
    return buildWirelessRGBCommitReportVariant(report, 32, false);
}

static bool buildWirelessRGBLEDModeReportVariant(
    int mode,
    int brightness,
    int speed,
    int direction,
    int colorful,
    int color,
    uint8_t *report,
    size_t length,
    bool includeReportID
) {
    if (!report || length < (includeReportID ? 33 : 32) || mode < 0 || mode > 31 || brightness < 0 || brightness > 5 || speed < 0 || speed > 5 || direction < 0 || direction > 255 || colorful < 0 || colorful > 255 || color < 0 || color > 0xffffff) {
        return false;
    }

    memset(report, 0, length);
    size_t base = includeReportID ? 1 : 0;
    size_t checksumIndex = includeReportID ? 32 : 31;
    report[base + 0] = 0x05;
    report[base + 1] = 0x10;
    report[base + 2] = 0x00;
    report[base + 3] = (uint8_t)mode;
    if (mode != 0) {
        report[base + 4] = (uint8_t)(color & 0xff);
        report[base + 5] = (uint8_t)((color >> 8) & 0xff);
        report[base + 6] = (uint8_t)((color >> 16) & 0xff);
        report[base + 11] = (uint8_t)colorful;
        report[base + 12] = (uint8_t)brightness;
        report[base + 13] = (uint8_t)speed;
        report[base + 14] = (uint8_t)direction;
    }
    report[base + 17] = 0xaa;
    report[base + 18] = 0x55;

    char error[160] = {0};
    return applyRawChecksum(report, length, (int)checksumIndex, error, sizeof(error));
}

static bool buildWirelessRGBLEDModeReport(
    int mode,
    int brightness,
    int speed,
    int direction,
    int colorful,
    int color,
    uint8_t report[32]
) {
    return buildWirelessRGBLEDModeReportVariant(mode, brightness, speed, direction, colorful, color, report, 32, false);
}

static bool sendWirelessRGBOutputReportToPage(DeviceMonitor *monitor, int usagePage, const uint8_t *report, CFIndex reportLength, bool padReport, const char *label) {
    if (!monitor || !report) {
        return false;
    }
    if (monitor->usagePage != usagePage) {
        return false;
    }
    if (monitor->outputSize <= 0) {
        printf("%s skipped for page=0x%04x: endpoint has no output report size.\n", label, monitor->usagePage);
        fflush(stdout);
        return false;
    }

    CFIndex length = padReport ? monitor->outputSize : reportLength;
    if (length > monitor->outputSize) {
        printf("%s skipped for page=0x%04x: output report size is %d.\n", label, monitor->usagePage, monitor->outputSize);
        fflush(stdout);
        return false;
    }

    uint8_t *payload = calloc((size_t)length, sizeof(uint8_t));
    if (!payload) {
        printf("%s skipped for page=0x%04x: allocation failed.\n", label, monitor->usagePage);
        fflush(stdout);
        return false;
    }
    memcpy(payload, report, (size_t)reportLength);

    IOReturn result = IOHIDDeviceSetReport(monitor->device, kIOHIDReportTypeOutput, 0, payload, length);
    printf("%s sent to page=0x%04x len=%ld result=0x%08x bytes=", label, monitor->usagePage, (long)length, result);
    printHex(payload, length);
    printf("\n");
    fflush(stdout);
    free(payload);
    return result == kIOReturnSuccess;
}

static bool sendWirelessRGBOutputReport(DeviceMonitor *monitor, const uint8_t report[32], const char *label) {
    return sendWirelessRGBOutputReportToPage(monitor, 0xff60, report, 32, false, label);
}

static bool sendWirelessRGBModeReports(DeviceMonitor *monitors, CFIndex count, int mode) {
    uint8_t report[32] = {0};
    if (!buildWirelessRGBModeReport(mode, report)) {
        printf("RGB mode send skipped: mode %d is outside the supported 0..31 probe range.\n", mode);
        fflush(stdout);
        return false;
    }

    bool sent = false;
    for (CFIndex i = 0; i < count; i++) {
        DeviceMonitor *monitor = &monitors[i];
        if (monitor->usagePage != 0xff60) {
            continue;
        }
        char label[80] = {0};
        snprintf(label, sizeof(label), "Legacy RGB lightmode %d", mode);
        sent = sendWirelessRGBOutputReport(monitor, report, label) || sent;
    }

    if (!sent) {
        printf("RGB mode send found no usable 2.4G raw HID endpoint.\n");
        fflush(stdout);
    }
    return sent;
}

static bool sendWirelessRGBCommitReportsVariant(DeviceMonitor *monitors, CFIndex count, int usagePage, bool includeReportID, bool padReport) {
    uint8_t report[64] = {0};
    CFIndex reportLength = includeReportID ? 33 : 32;
    if (!buildWirelessRGBCommitReportVariant(report, (size_t)reportLength, includeReportID)) {
        printf("RGB commit send skipped: could not build commit report.\n");
        fflush(stdout);
        return false;
    }

    bool sent = false;
    for (CFIndex i = 0; i < count; i++) {
        sent = sendWirelessRGBOutputReportToPage(&monitors[i], usagePage, report, reportLength, padReport, "RGB commit probe") || sent;
    }
    if (!sent) {
        printf("RGB commit send found no usable 2.4G HID endpoint for page=0x%04x.\n", usagePage);
        fflush(stdout);
    }
    return sent;
}

static bool sendWirelessRGBCommitReports(DeviceMonitor *monitors, CFIndex count) {
    return sendWirelessRGBCommitReportsVariant(monitors, count, 0xff60, false, false);
}

static bool buildWirelessKeyResponseReportVariant(
    int fnSwitch,
    int sleepTime,
    int responseLevel,
    bool includeFnLayer,
    bool includeSleepTime,
    bool includeResponseTime,
    uint8_t *report,
    size_t length,
    bool includeReportID
) {
    if (!report || length < (includeReportID ? 33 : 32)) {
        return false;
    }
    if ((includeFnLayer && (fnSwitch < 0 || fnSwitch > 1)) ||
        (includeSleepTime && (sleepTime < 0 || sleepTime > 255)) ||
        (includeResponseTime && (responseLevel < 1 || responseLevel > 5))) {
        return false;
    }

    memset(report, 0, length);
    size_t base = includeReportID ? 1 : 0;
    size_t checksumIndex = includeReportID ? 32 : 31;

    report[base + 0] = 0x07;
    report[base + 1] = 0x10;
    report[base + 2] = 0x00;
    report[base + 3] = 0x00;
    report[base + 4] = 0x01;
    report[base + 5] = includeFnLayer ? 0x01 : 0x00;
    report[base + 6] = includeSleepTime ? 0x01 : 0x00;
    report[base + 7] = includeResponseTime ? 0x01 : 0x00;
    if (includeFnLayer) {
        report[base + 8] = (uint8_t)fnSwitch;
    }
    if (includeSleepTime) {
        report[base + 9] = (uint8_t)sleepTime;
    }
    if (includeResponseTime) {
        report[base + 11] = (uint8_t)responseLevel;
    }
    report[base + 17] = 0xaa;
    report[base + 18] = 0x55;

    char error[160] = {0};
    return applyRawChecksum(report, length, (int)checksumIndex, error, sizeof(error));
}

static const char *keyResponseLevelDescription(int responseLevel) {
    switch (responseLevel) {
        case 1:
            return "wired 2-3ms, 2.4G 5-6ms, Bluetooth 12-13ms";
        case 2:
            return "wired 5-6ms, 2.4G 7-9ms, Bluetooth 15-16ms";
        case 3:
            return "wired 8-9ms, 2.4G 10-12ms, Bluetooth 18-19ms";
        case 4:
            return "wired 13-14ms, 2.4G 15-17ms, Bluetooth 23-24ms";
        case 5:
            return "wired 17-18ms, 2.4G 19-21ms, Bluetooth 27-28ms";
        default:
            return "unknown";
    }
}

static bool sendWirelessKeyResponseReports(
    DeviceMonitor *monitors,
    CFIndex count,
    int responseLevel,
    int fnSwitch,
    int sleepTime,
    bool includeFnLayer,
    bool includeSleepTime,
    bool sendCommitFirst,
    int usagePage,
    bool includeReportID,
    bool padReport
) {
    uint8_t report[64] = {0};
    CFIndex reportLength = includeReportID ? 33 : 32;
    if (!buildWirelessKeyResponseReportVariant(fnSwitch, sleepTime, responseLevel, includeFnLayer, includeSleepTime, true, report, (size_t)reportLength, includeReportID)) {
        printf(
            "Key response send skipped: responseLevel=%d fnLayer=%s%d sleepTime=%s%d is outside the probe range.\n",
            responseLevel,
            includeFnLayer ? "" : "(ignored) ",
            fnSwitch,
            includeSleepTime ? "" : "(ignored) ",
            sleepTime
        );
        fflush(stdout);
        return false;
    }

    bool sent = false;
    if (sendCommitFirst) {
        sent = sendWirelessRGBCommitReportsVariant(monitors, count, usagePage, includeReportID, padReport);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }

    for (CFIndex i = 0; i < count; i++) {
        char label[160] = {0};
        snprintf(
            label,
            sizeof(label),
            "Key response level %d (%s)",
            responseLevel,
            keyResponseLevelDescription(responseLevel)
        );
        sent = sendWirelessRGBOutputReportToPage(&monitors[i], usagePage, report, reportLength, padReport, label) || sent;
    }

    if (!sent) {
        printf("Key response send found no usable 2.4G HID endpoint for page=0x%04x.\n", usagePage);
        fflush(stdout);
    }
    return sent;
}

static bool buildWirelessGameModeReportVariant(
    int responseLevel,
    int fnSwitch,
    int sleepTime,
    int gameMode,
    int disableAltTab,
    int disableAltF4,
    int disableWin,
    uint8_t *report,
    size_t length,
    bool includeReportID
) {
    if (!report || length < (includeReportID ? 33 : 32) ||
        responseLevel < 1 || responseLevel > 5 ||
        fnSwitch < 0 || fnSwitch > 1 ||
        sleepTime < 0 || sleepTime > 3 ||
        gameMode < 0 || gameMode > 1 ||
        disableAltTab < 0 || disableAltTab > 1 ||
        disableAltF4 < 0 || disableAltF4 > 1 ||
        disableWin < 0 || disableWin > 1) {
        return false;
    }

    memset(report, 0, length);
    size_t base = includeReportID ? 1 : 0;
    size_t checksumIndex = includeReportID ? 32 : 31;

    report[base + 0] = 0x07;
    report[base + 1] = 0x10;
    report[base + 2] = 0x00;
    report[base + 3] = 0x00;
    report[base + 4] = 0x01;
    report[base + 5] = 0x01;
    report[base + 6] = 0x01;
    report[base + 7] = 0x01;
    report[base + 8] = (uint8_t)fnSwitch;
    report[base + 9] = (uint8_t)sleepTime;
    report[base + 11] = (uint8_t)responseLevel;
    report[base + 12] = (uint8_t)gameMode;
    report[base + 13] = (uint8_t)disableAltTab;
    report[base + 14] = (uint8_t)disableAltF4;
    report[base + 15] = (uint8_t)disableWin;
    report[base + 17] = 0xaa;
    report[base + 18] = 0x55;

    char error[160] = {0};
    return applyRawChecksum(report, length, (int)checksumIndex, error, sizeof(error));
}

static bool sendWirelessGameModeReports(
    DeviceMonitor *monitors,
    CFIndex count,
    int gameMode,
    int responseLevel,
    int fnSwitch,
    int sleepTime,
    int disableAltTab,
    int disableAltF4,
    int disableWin,
    int usagePage,
    bool includeReportID,
    bool padReport
) {
    uint8_t report[64] = {0};
    CFIndex reportLength = includeReportID ? 33 : 32;
    if (!buildWirelessGameModeReportVariant(responseLevel, fnSwitch, sleepTime, gameMode, disableAltTab, disableAltF4, disableWin, report, (size_t)reportLength, includeReportID)) {
        printf(
            "Game mode send skipped: gameMode=%d responseLevel=%d fnSwitch=%d sleepTime=%d disableAltTab=%d disableAltF4=%d disableWin=%d is outside the probe range.\n",
            gameMode,
            responseLevel,
            fnSwitch,
            sleepTime,
            disableAltTab,
            disableAltF4,
            disableWin
        );
        fflush(stdout);
        return false;
    }

    bool sent = false;
    for (CFIndex i = 0; i < count; i++) {
        char label[180] = {0};
        snprintf(
            label,
            sizeof(label),
            "Actual game mode %s win=%d altTab=%d altF4=%d response=%d sleep=%d",
            gameMode ? "on" : "off",
            disableWin,
            disableAltTab,
            disableAltF4,
            responseLevel,
            sleepTime
        );
        sent = sendWirelessRGBOutputReportToPage(&monitors[i], usagePage, report, reportLength, padReport, label) || sent;
    }

    if (!sent) {
        printf("Game mode send found no usable 2.4G HID endpoint for page=0x%04x.\n", usagePage);
        fflush(stdout);
    }
    return sent;
}

static bool sendWirelessRGBLEDModeReports(
    DeviceMonitor *monitors,
    CFIndex count,
    int mode,
    int brightness,
    int speed,
    int direction,
    int colorful,
    int color,
    bool sendCommitFirst,
    int usagePage,
    bool includeReportID,
    bool padReport
) {
    uint8_t report[64] = {0};
    CFIndex reportLength = includeReportID ? 33 : 32;
    if (!buildWirelessRGBLEDModeReportVariant(mode, brightness, speed, direction, colorful, color, report, (size_t)reportLength, includeReportID)) {
        printf(
            "RGB LED mode send skipped: mode=%d brightness=%d speed=%d direction=%d colorful=%d color=0x%06x is outside the probe range.\n",
            mode,
            brightness,
            speed,
            direction,
            colorful,
            color
        );
        fflush(stdout);
        return false;
    }

    bool sent = false;
    if (sendCommitFirst) {
        sent = sendWirelessRGBCommitReportsVariant(monitors, count, usagePage, includeReportID, padReport);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }

    for (CFIndex i = 0; i < count; i++) {
        char label[120] = {0};
        snprintf(
            label,
            sizeof(label),
            "RGB LED mode %d brightness %d speed %d color 0x%06x",
            mode,
            brightness,
            speed,
            color
        );
        sent = sendWirelessRGBOutputReportToPage(&monitors[i], usagePage, report, reportLength, padReport, label) || sent;
    }

    if (!sent) {
        printf("RGB LED mode send found no usable 2.4G HID endpoint for page=0x%04x.\n", usagePage);
        fflush(stdout);
    }
    return sent;
}

static bool sendRGBStandardFeatureReportToPage(DeviceMonitor *monitor, int usagePage, const uint8_t body[64], bool includeReportID, const char *label) {
    if (!monitor || !body || monitor->usagePage != usagePage) {
        return false;
    }

    uint8_t payload[65] = {0};
    CFIndex length = includeReportID ? 65 : 64;
    if (includeReportID) {
        memcpy(payload + 1, body, 64);
    } else {
        memcpy(payload, body, 64);
    }

    IOReturn result = IOHIDDeviceSetReport(monitor->device, kIOHIDReportTypeFeature, 0, payload, length);
    printf("%s feature sent to page=0x%04x len=%ld shape=%s result=0x%08x bytes=", label, monitor->usagePage, (long)length, includeReportID ? "report-id" : "body", result);
    printHex(payload, length);
    printf("\n");
    fflush(stdout);
    return result == kIOReturnSuccess;
}

static bool sendRGBStandardFeatureBody(DeviceMonitor *monitors, CFIndex count, int usagePage, const uint8_t body[64], bool includeReportID, const char *label) {
    bool sent = false;
    for (CFIndex i = 0; i < count; i++) {
        sent = sendRGBStandardFeatureReportToPage(&monitors[i], usagePage, body, includeReportID, label) || sent;
    }
    if (!sent) {
        printf("%s feature send found no usable HID endpoint for page=0x%04x.\n", label, usagePage);
        fflush(stdout);
    }
    return sent;
}

static bool sendRGBStandardOutputReportToPage(DeviceMonitor *monitor, int usagePage, const uint8_t body[64], bool includeReportID, const char *label) {
    if (!monitor || !body || monitor->usagePage != usagePage) {
        return false;
    }
    if (monitor->outputSize <= 0) {
        printf("%s output skipped for page=0x%04x: endpoint has no output report size.\n", label, monitor->usagePage);
        fflush(stdout);
        return false;
    }

    CFIndex length = monitor->outputSize;
    if (length > 64) {
        length = 64;
    }
    uint8_t payload[64] = {0};
    if (includeReportID) {
        if (length > 1) {
            memcpy(payload + 1, body, (size_t)(length - 1));
        }
    } else {
        memcpy(payload, body, (size_t)length);
    }

    IOReturn result = IOHIDDeviceSetReport(monitor->device, kIOHIDReportTypeOutput, 0, payload, length);
    printf("%s output sent to page=0x%04x len=%ld shape=%s result=0x%08x bytes=", label, monitor->usagePage, (long)length, includeReportID ? "report-id" : "body", result);
    printHex(payload, length);
    printf("\n");
    fflush(stdout);
    return result == kIOReturnSuccess;
}

static bool sendRGBStandardOutputBody(DeviceMonitor *monitors, CFIndex count, int usagePage, const uint8_t body[64], bool includeReportID, const char *label) {
    bool sent = false;
    for (CFIndex i = 0; i < count; i++) {
        sent = sendRGBStandardOutputReportToPage(&monitors[i], usagePage, body, includeReportID, label) || sent;
    }
    if (!sent) {
        printf("%s output send found no usable HID endpoint for page=0x%04x.\n", label, usagePage);
        fflush(stdout);
    }
    return sent;
}

static bool sendRGBStandardBody(DeviceMonitor *monitors, CFIndex count, int usagePage, const uint8_t body[64], bool useOutput, bool includeReportID, const char *label) {
    if (useOutput) {
        return sendRGBStandardOutputBody(monitors, count, usagePage, body, includeReportID, label);
    }
    return sendRGBStandardFeatureBody(monitors, count, usagePage, body, includeReportID, label);
}

static bool sendWirelessRGBStandardModeReports(
    DeviceMonitor *monitors,
    CFIndex count,
    int mode,
    int brightness,
    int speed,
    int direction,
    int colorful,
    int color,
    bool sendCommitFirst,
    int usagePage,
    bool useOutput,
    bool includeReportID
) {
    if (mode < 0 || mode > 31 || brightness < 0 || brightness > 5 || speed < 0 || speed > 5 || direction < 0 || direction > 255 || colorful < 0 || colorful > 255 || color < 0 || color > 0xffffff) {
        printf(
            "RGB standard feature send skipped: mode=%d brightness=%d speed=%d direction=%d colorful=%d color=0x%06x is outside the probe range.\n",
            mode,
            brightness,
            speed,
            direction,
            colorful,
            color
        );
        fflush(stdout);
        return false;
    }

    bool sent = false;
    if (sendCommitFirst) {
        sent = sendWirelessRGBCommitReportsVariant(monitors, count, usagePage, true, true);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }

    uint8_t body[64] = {0};
    body[0] = 0x04;
    body[1] = 0x18;
    sent = sendRGBStandardBody(monitors, count, usagePage, body, useOutput, includeReportID, "RGB standard begin") || sent;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);

    memset(body, 0, sizeof(body));
    body[0] = 0x04;
    body[1] = 0x13;
    body[8] = 0x01;
    sent = sendRGBStandardBody(monitors, count, usagePage, body, useOutput, includeReportID, "RGB standard select") || sent;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);

    memset(body, 0, sizeof(body));
    body[0] = (uint8_t)mode;
    if (mode != 0) {
        body[1] = (uint8_t)(color & 0xff);
        body[2] = (uint8_t)((color >> 8) & 0xff);
        body[3] = (uint8_t)((color >> 16) & 0xff);
        body[8] = (uint8_t)colorful;
        body[9] = (uint8_t)brightness;
        body[10] = (uint8_t)speed;
        body[11] = (uint8_t)direction;
    }
    body[14] = 0xaa;
    body[15] = 0x55;
    sent = sendRGBStandardBody(monitors, count, usagePage, body, useOutput, includeReportID, "RGB standard payload") || sent;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);

    memset(body, 0, sizeof(body));
    body[0] = 0x04;
    body[1] = 0x02;
    sent = sendRGBStandardBody(monitors, count, usagePage, body, useOutput, includeReportID, "RGB standard apply") || sent;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);

    memset(body, 0, sizeof(body));
    body[0] = 0x04;
    body[1] = 0xf0;
    sent = sendRGBStandardBody(monitors, count, usagePage, body, useOutput, includeReportID, "RGB standard finish") || sent;

    return sent;
}

static void readFeatureReports(DeviceMonitor *monitor) {
    if (monitor->featureSize <= 0) {
        return;
    }

    for (uint32_t reportID = 0; reportID <= 15; reportID++) {
        CFIndex length = monitor->featureSize;
        uint8_t *payload = calloc((size_t)length, sizeof(uint8_t));
        if (!payload) {
            return;
        }

        IOReturn result = IOHIDDeviceGetReport(
            monitor->device,
            kIOHIDReportTypeFeature,
            reportID,
            payload,
            &length
        );

        printf(
            "Feature read page=0x%04x reportID=%u result=0x%08x len=%ld bytes=",
            monitor->usagePage,
            reportID,
            result,
            (long)length
        );
        printHex(payload, length);
        printf("\n");
        fflush(stdout);
        free(payload);
    }
}

static void sendViaProtocolQuery(DeviceMonitor *monitor) {
    if (monitor->outputSize <= 0) {
        return;
    }

    uint8_t *payload = calloc((size_t)monitor->outputSize, sizeof(uint8_t));
    payload[0] = 0x01; // QMK/VIA id_get_protocol_version

    IOReturn result = IOHIDDeviceSetReport(
        monitor->device,
        kIOHIDReportTypeOutput,
        0,
        payload,
        monitor->outputSize
    );

    printf(
        "Sent VIA protocol query to page=0x%04x len=%d result=0x%08x bytes=",
        monitor->usagePage,
        monitor->outputSize,
        result
    );
    printHex(payload, monitor->outputSize);
    printf("\n");
    fflush(stdout);
    free(payload);
}

static void sendBatteryQueryVariant(DeviceMonitor *monitor, bool includeReportID, CFIndex length) {
    if (monitor->outputSize <= 0) {
        return;
    }
    if (monitor->usagePage != 0xff13 && monitor->usagePage != 0xff59 && monitor->usagePage != 0xff60) {
        return;
    }

    if (length <= 0 || length > monitor->outputSize) {
        length = monitor->outputSize;
    }

    uint8_t *payload = calloc((size_t)length, sizeof(uint8_t));
    if (!payload) {
        return;
    }

    if (includeReportID) {
        payload[0] = 0x00;
        if (length > 1) {
            payload[1] = 0x20;
        }
        if (length > 2) {
            payload[2] = 0x01;
        }
    } else {
        payload[0] = 0x20;
        if (length > 1) {
            payload[1] = 0x01;
        }
    }

    uint8_t sum = 0;
    for (CFIndex i = 0; i < length; i++) {
        sum = (uint8_t)(sum + payload[i]);
    }
    if (includeReportID && length > 32) {
        payload[32] = sum;
    } else if (!includeReportID && length > 31) {
        payload[31] = sum;
    }

    IOReturn result = IOHIDDeviceSetReport(
        monitor->device,
        kIOHIDReportTypeOutput,
        0,
        payload,
        length
    );

    printf(
        "Sent battery query to page=0x%04x shape=%s len=%ld result=0x%08x bytes=",
        monitor->usagePage,
        includeReportID ? "win" : "mac",
        (long)length,
        result
    );
    printHex(payload, length);
    printf("\n");
    fflush(stdout);
    free(payload);
}

static void sendBatteryQuery(DeviceMonitor *monitor) {
    CFIndex cappedOutput = monitor->outputSize > 64 ? 64 : monitor->outputSize;
    sendBatteryQueryVariant(monitor, false, cappedOutput);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    sendBatteryQueryVariant(monitor, true, cappedOutput);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    sendBatteryQueryVariant(monitor, false, monitor->outputSize >= 33 ? 33 : monitor->outputSize);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    sendBatteryQueryVariant(monitor, true, monitor->outputSize >= 33 ? 33 : monitor->outputSize);
}

static IOReturn sendScreenControlCommandVariant(
    DeviceMonitor *monitor,
    const uint8_t *bytes,
    CFIndex length,
    const char *label,
    bool prefixed,
    bool readAck
) {
    int maxReportSize = monitor->featureSize > 0 ? monitor->featureSize : monitor->outputSize;
    if (monitor->usagePage != 0xff13 || maxReportSize <= 0) {
        return kIOReturnNoDevice;
    }

    CFIndex reportLength = maxReportSize > 64 ? 64 : maxReportSize;
    if (prefixed) {
        reportLength++;
    }
    if (reportLength < 1) {
        return kIOReturnNoDevice;
    }

    uint8_t *payload = calloc((size_t)reportLength, sizeof(uint8_t));
    if (!payload) {
        return kIOReturnNoMemory;
    }

    CFIndex base = prefixed ? 1 : 0;
    CFIndex maxCommandLength = reportLength - base;
    if (length > maxCommandLength) {
        length = maxCommandLength;
    }
    memcpy(payload + base, bytes, (size_t)length);

    IOReturn result = IOHIDDeviceSetReport(
        monitor->device,
        kIOHIDReportTypeFeature,
        0,
        payload,
        reportLength
    );

    printf(
        "Sent screen control feature %s%s to page=0x%04x len=%ld result=0x%08x bytes=",
        label,
        prefixed ? " prefixed" : "",
        monitor->usagePage,
        (long)reportLength,
        result
    );
    printHex(payload, reportLength);
    printf("\n");
    fflush(stdout);

    if (result == kIOReturnSuccess && readAck && monitor->inputSize > 0) {
        CFIndex ackLength = monitor->inputSize;
        uint8_t *ack = calloc((size_t)ackLength, sizeof(uint8_t));
        if (ack) {
            IOReturn ackResult = IOHIDDeviceGetReport(
                monitor->device,
                kIOHIDReportTypeInput,
                0,
                ack,
                &ackLength
            );
            printf(
                "Read screen control ack %s%s result=0x%08x len=%ld ackByte3=%s bytes=",
                label,
                prefixed ? " prefixed" : "",
                ackResult,
                (long)ackLength,
                ackLength > 3 && ack[3] == 0x01 ? "yes" : "no"
            );
            printHex(ack, ackLength < 16 ? ackLength : 16);
            printf("\n");
            fflush(stdout);
            free(ack);
        }

        if (monitor->featureSize > 0) {
            CFIndex featureLength = monitor->featureSize;
            uint8_t *feature = calloc((size_t)featureLength, sizeof(uint8_t));
            if (feature) {
                IOReturn featureResult = IOHIDDeviceGetReport(
                    monitor->device,
                    kIOHIDReportTypeFeature,
                    0,
                    feature,
                    &featureLength
                );
                printf(
                    "Read screen control feature ack %s%s result=0x%08x len=%ld ackByte3=%s bytes=",
                    label,
                    prefixed ? " prefixed" : "",
                    featureResult,
                    (long)featureLength,
                    featureLength > 3 && feature[3] == 0x01 ? "yes" : "no"
                );
                printHex(feature, featureLength < 16 ? featureLength : 16);
                printf("\n");
                fflush(stdout);
                free(feature);
            }
        }
    }

    free(payload);
    return result;
}

static IOReturn sendScreenControlCommand(DeviceMonitor *monitor, const uint8_t *bytes, CFIndex length, const char *label) {
    return sendScreenControlCommandVariant(monitor, bytes, length, label, false, false);
}

static void sendScreenExitProbe(DeviceMonitor *monitor) {
    const uint8_t exitCommand[] = {0x04, 0x02};
    sendScreenControlCommand(monitor, exitCommand, sizeof(exitCommand), "exit");
}

static void sendScreenHandshakeProbe(DeviceMonitor *monitor) {
    const uint8_t beginCommand[] = {0x04, 0x18};
    const uint8_t exitCommand[] = {0x04, 0x02};
    sendScreenControlCommand(monitor, beginCommand, sizeof(beginCommand), "begin");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    sendScreenControlCommand(monitor, exitCommand, sizeof(exitCommand), "exit");
}

static DeviceMonitor *findMonitor(DeviceMonitor *monitors, CFIndex count, int usagePage);

static void sendScreenTimeSync(DeviceMonitor *monitors, CFIndex count) {
    DeviceMonitor *control = findMonitor(monitors, count, 0xff13);
    if (!control) {
        printf("Screen time sync needs the 0xff13 control endpoint.\n");
        fflush(stdout);
        return;
    }

    NSDateComponents *components = [[NSCalendar currentCalendar] components:
        NSCalendarUnitYear |
        NSCalendarUnitMonth |
        NSCalendarUnitDay |
        NSCalendarUnitHour |
        NSCalendarUnitMinute |
        NSCalendarUnitSecond |
        NSCalendarUnitWeekday
        fromDate:[NSDate date]];

    uint8_t command[64] = {0};
    const uint8_t beginCommand[] = {0x04, 0x18};
    const uint8_t selectCommand[] = {0x04, 0x28, 0, 0, 0, 0, 0, 0, 0x01};
    const uint8_t exitCommand[] = {0x04, 0x02};

    command[0] = 0x00;
    command[1] = 0x01;
    command[2] = 0x5a;
    command[3] = (uint8_t)(components.year >= 2000 ? components.year - 2000 : components.year % 100);
    command[4] = (uint8_t)components.month;
    command[5] = (uint8_t)components.day;
    command[6] = (uint8_t)components.hour;
    command[7] = (uint8_t)components.minute;
    command[8] = (uint8_t)components.second;
    command[10] = (uint8_t)(components.weekday > 0 ? components.weekday - 1 : 0);
    command[62] = 0xaa;
    command[63] = 0x55;

    printf("Sending screen time sync and image-mode select.\n");
    fflush(stdout);
    sendScreenControlCommand(control, beginCommand, sizeof(beginCommand), "sync-begin");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    sendScreenControlCommand(control, selectCommand, sizeof(selectCommand), "sync-select");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    sendScreenControlCommand(control, command, sizeof(command), "sync-time");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    sendScreenControlCommand(control, exitCommand, sizeof(exitCommand), "sync-exit");
}

static DeviceMonitor *findMonitor(DeviceMonitor *monitors, CFIndex count, int usagePage) {
    for (CFIndex i = 0; i < count; i++) {
        if (monitors[i].usagePage == usagePage) {
            return &monitors[i];
        }
    }
    return NULL;
}

static uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return (uint16_t)(((uint16_t)(r & 0xf8) << 8) | ((uint16_t)(g & 0xfc) << 3) | (b >> 3));
}

static void writeScreenPixel(uint8_t *stream, size_t offset, uint8_t r, uint8_t g, uint8_t b, ScreenPixelFormat format) {
    uint16_t color = format == ScreenPixelBGR565LE || format == ScreenPixelBGR565BE ? rgb565(b, g, r) : rgb565(r, g, b);
    if (format == ScreenPixelRGB565BE || format == ScreenPixelBGR565BE) {
        stream[offset] = (uint8_t)(color >> 8);
        stream[offset + 1] = (uint8_t)(color & 0xff);
    } else {
        stream[offset] = (uint8_t)(color & 0xff);
        stream[offset + 1] = (uint8_t)(color >> 8);
    }
}

static size_t screenPixelIndex(size_t x, size_t y, size_t width, size_t height, ScreenPixelLayout layout) {
    switch (layout) {
        case ScreenLayoutFlipX:
            return y * width + (width - 1 - x);
        case ScreenLayoutFlipY:
            return (height - 1 - y) * width + x;
        case ScreenLayoutRotate180:
            return (height - 1 - y) * width + (width - 1 - x);
        case ScreenLayoutRowSnake:
            return y * width + ((y & 1) ? (width - 1 - x) : x);
        case ScreenLayoutColumnMajor:
            return x * height + y;
        case ScreenLayoutColumnFlipX:
            return (width - 1 - x) * height + y;
        case ScreenLayoutColumnFlipY:
            return x * height + (height - 1 - y);
        case ScreenLayoutTile8: {
            const size_t tile = 8;
            size_t tilesPerRow = width / tile;
            size_t tileIndex = (y / tile) * tilesPerRow + (x / tile);
            return tileIndex * tile * tile + (y % tile) * tile + (x % tile);
        }
        case ScreenLayoutTile16: {
            const size_t tile = 16;
            size_t tilesPerRow = width / tile;
            size_t tileIndex = (y / tile) * tilesPerRow + (x / tile);
            return tileIndex * tile * tile + (y % tile) * tile + (x % tile);
        }
        case ScreenLayoutRowMajor:
        default:
            return y * width + x;
    }
}

static void writeScreenPixelAt(
    uint8_t *stream,
    size_t frameOffset,
    size_t x,
    size_t y,
    size_t width,
    size_t height,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    ScreenPixelFormat format,
    ScreenPixelLayout layout
) {
    size_t pixelOffset = frameOffset + (screenPixelIndex(x, y, width, height, layout) * 2);
    writeScreenPixel(stream, pixelOffset, r, g, b, format);
}

static uint8_t *createScreenTestStream(
    size_t *streamLength,
    size_t *payloadLengthOut,
    uint16_t *chunkCount,
    uint8_t frameCount,
    uint8_t frameDelay,
    ScreenPixelFormat pixelFormat,
    ScreenPixelLayout pixelLayout
) {
    const size_t width = 128;
    const size_t height = 128;
    const size_t headerLength = 256;
    const size_t frameBytes = width * height * 2;
    const size_t payloadLength = headerLength + ((size_t)frameCount * frameBytes);
    const size_t chunks = (payloadLength + 4095) / 4096;
    const size_t paddedLength = chunks * 4096;

    uint8_t *stream = malloc(paddedLength);
    if (!stream) {
        return NULL;
    }
    memset(stream, 0x00, paddedLength);

    stream[0] = frameCount;
    for (uint8_t frame = 0; frame < frameCount; frame++) {
        stream[1 + frame] = frameDelay;
    }

    for (uint8_t frame = 0; frame < frameCount; frame++) {
        size_t frameOffset = headerLength + ((size_t)frame * frameBytes);
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                uint8_t r = (uint8_t)((x * 255) / (width - 1));
                uint8_t g = (uint8_t)((y * 255) / (height - 1));
                uint8_t b = (uint8_t)(255 - ((x + y) * 255) / ((width - 1) + (height - 1)));

                if (x < 4 || y < 4 || x >= width - 4 || y >= height - 4) {
                    r = 255;
                    g = 255;
                    b = 255;
                } else if (x == y || x + y == width - 1) {
                    r = 255;
                    g = 255;
                    b = 255;
                }

                writeScreenPixelAt(stream, frameOffset, x, y, width, height, r, g, b, pixelFormat, pixelLayout);
            }
        }
    }

    *streamLength = paddedLength;
    if (payloadLengthOut) {
        *payloadLengthOut = payloadLength;
    }
    *chunkCount = (uint16_t)chunks;
    return stream;
}

static bool diagnosticDigitPixel(int digit, size_t x, size_t y) {
    static const uint8_t masks[] = {
        0x3f, 0x06, 0x5b, 0x4f, 0x66,
        0x6d, 0x7d, 0x07, 0x7f, 0x6f,
    };
    if (digit < 0 || digit > 9) {
        return false;
    }
    uint8_t mask = masks[digit];
    const size_t left = 34;
    const size_t right = 94;
    const size_t top = 18;
    const size_t mid = 60;
    const size_t bottom = 102;
    const size_t thick = 9;
    bool a = (mask & 0x01) && y >= top && y < top + thick && x >= left + thick && x < right - thick;
    bool b = (mask & 0x02) && x >= right - thick && x < right && y >= top + thick && y < mid;
    bool c = (mask & 0x04) && x >= right - thick && x < right && y >= mid + thick && y < bottom;
    bool d = (mask & 0x08) && y >= bottom && y < bottom + thick && x >= left + thick && x < right - thick;
    bool e = (mask & 0x10) && x >= left && x < left + thick && y >= mid + thick && y < bottom;
    bool f = (mask & 0x20) && x >= left && x < left + thick && y >= top + thick && y < mid;
    bool g = (mask & 0x40) && y >= mid && y < mid + thick && x >= left + thick && x < right - thick;
    return a || b || c || d || e || f || g;
}

static void diagnosticPixel(size_t variant, size_t x, size_t y, uint8_t *r, uint8_t *g, uint8_t *b) {
    static const uint8_t colors[][3] = {
        {40, 50, 180}, {180, 40, 40}, {40, 150, 70}, {190, 150, 20}, {150, 50, 160},
        {20, 150, 170}, {230, 90, 20}, {90, 90, 90}, {30, 110, 210}, {210, 210, 210},
    };
    const size_t colorCount = sizeof(colors) / sizeof(colors[0]);
    *r = colors[variant % colorCount][0];
    *g = colors[variant % colorCount][1];
    *b = colors[variant % colorCount][2];

    if (x < 4 || y < 4 || x >= 124 || y >= 124) {
        *r = 255;
        *g = 255;
        *b = 255;
    } else if (x < 12) {
        *r = 255;
        *g = 0;
        *b = 0;
    } else if (y < 12) {
        *r = 0;
        *g = 255;
        *b = 0;
    } else if ((x % 32) < 2 || (y % 32) < 2) {
        *r = (uint8_t)(*r / 2);
        *g = (uint8_t)(*g / 2);
        *b = (uint8_t)(*b / 2);
    }

    int digit = (int)((variant + 1) % 10);
    if (diagnosticDigitPixel(digit, x, y)) {
        *r = 255;
        *g = 255;
        *b = 255;
    }
}

static uint8_t *createScreenLayoutScanStream(
    size_t *streamLength,
    size_t *payloadLengthOut,
    uint16_t *chunkCount,
    ScreenPixelFormat pixelFormat
) {
    static const ScreenPixelLayout layouts[] = {
        ScreenLayoutRowMajor,
        ScreenLayoutFlipX,
        ScreenLayoutFlipY,
        ScreenLayoutRotate180,
        ScreenLayoutRowSnake,
        ScreenLayoutColumnMajor,
        ScreenLayoutColumnFlipX,
        ScreenLayoutColumnFlipY,
        ScreenLayoutTile8,
        ScreenLayoutTile16,
    };
    const size_t layoutCount = sizeof(layouts) / sizeof(layouts[0]);
    const size_t repeats = 6;
    const uint8_t frameCount = (uint8_t)(layoutCount * repeats);
    const size_t width = 128;
    const size_t height = 128;
    const size_t headerLength = 256;
    const size_t frameBytes = width * height * 2;
    const size_t payloadLength = headerLength + ((size_t)frameCount * frameBytes);
    const size_t chunks = (payloadLength + 4095) / 4096;
    const size_t paddedLength = chunks * 4096;
    uint8_t *stream = malloc(paddedLength);
    if (!stream) {
        return NULL;
    }
    memset(stream, 0x00, paddedLength);
    stream[0] = frameCount;
    for (uint8_t frame = 0; frame < frameCount; frame++) {
        stream[1 + frame] = 255;
    }

    for (uint8_t frame = 0; frame < frameCount; frame++) {
        size_t variant = frame / repeats;
        ScreenPixelLayout layout = layouts[variant];
        size_t frameOffset = headerLength + ((size_t)frame * frameBytes);
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                uint8_t r = 0;
                uint8_t g = 0;
                uint8_t b = 0;
                diagnosticPixel(variant, x, y, &r, &g, &b);
                writeScreenPixelAt(stream, frameOffset, x, y, width, height, r, g, b, pixelFormat, layout);
            }
        }
    }

    printf("Layout scan card order:");
    for (size_t i = 0; i < layoutCount; i++) {
        printf(" %zu=%s", i + 1, screenPixelLayoutName(layouts[i]));
    }
    printf("\n");

    *streamLength = paddedLength;
    if (payloadLengthOut) {
        *payloadLengthOut = payloadLength;
    }
    *chunkCount = (uint16_t)chunks;
    return stream;
}

static uint8_t gifDelayByte(NSDictionary *properties) {
    NSDictionary *gif = properties[(NSString *)kCGImagePropertyGIFDictionary];
    NSNumber *delay = gif[(NSString *)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(NSString *)kCGImagePropertyGIFDelayTime];
    double seconds = [delay respondsToSelector:@selector(doubleValue)] ? [delay doubleValue] : 0.01;
    if (seconds <= 0.0) {
        seconds = 0.01;
    }

    int value = (int)llround(seconds * 500.0);
    if (value < 1) {
        value = 1;
    } else if (value > 255) {
        value = 255;
    }
    return (uint8_t)value;
}

static void writeCGImageFrame(
    uint8_t *stream,
    size_t frameOffset,
    CGImageRef image,
    size_t width,
    size_t height,
    ScreenFitMode fitMode,
    ScreenPixelFormat pixelFormat,
    ScreenPixelLayout pixelLayout
) {
    const size_t bytesPerPixel = 4;
    const size_t bytesPerRow = width * bytesPerPixel;

    size_t sourceWidth = CGImageGetWidth(image);
    size_t sourceHeight = CGImageGetHeight(image);
    if (sourceWidth == 0 || sourceHeight == 0) {
        return;
    }

    uint8_t *rgba = calloc(width * height, bytesPerPixel);
    if (!rgba) {
        return;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        rgba,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    if (!context) {
        CGColorSpaceRelease(colorSpace);
        free(rgba);
        return;
    }

    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);

    CGSize drawSize = CGSizeMake(width, height);
    if (fitMode != ScreenFitStretch) {
        CGFloat scaleX = (CGFloat)width / (CGFloat)sourceWidth;
        CGFloat scaleY = (CGFloat)height / (CGFloat)sourceHeight;
        CGFloat scale = fitMode == ScreenFitCover ? MAX(scaleX, scaleY) : MIN(scaleX, scaleY);
        drawSize = CGSizeMake((CGFloat)sourceWidth * scale, (CGFloat)sourceHeight * scale);
    }
    CGRect drawRect = CGRectMake(
        ((CGFloat)width - drawSize.width) / 2.0,
        ((CGFloat)height - drawSize.height) / 2.0,
        drawSize.width,
        drawSize.height
    );
    CGContextDrawImage(context, drawRect, image);

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t rgbaOffset = ((y * width) + x) * bytesPerPixel;
            writeScreenPixelAt(
                stream,
                frameOffset,
                x,
                y,
                width,
                height,
                rgba[rgbaOffset],
                rgba[rgbaOffset + 1],
                rgba[rgbaOffset + 2],
                pixelFormat,
                pixelLayout
            );
        }
    }

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(rgba);
}

static uint8_t *createScreenImageStream(
    const char *path,
    uint8_t stillFrameCount,
    uint8_t stillFrameDelay,
    uint8_t maxAnimatedFrames,
    size_t width,
    size_t height,
    ScreenFitMode fitMode,
    ScreenPixelFormat pixelFormat,
    ScreenPixelLayout pixelLayout,
    bool repeatFirstFrame,
    bool loopFill,
    size_t *streamLength,
    size_t *payloadLengthOut,
    uint16_t *chunkCount,
    uint8_t *frameCountOut,
    bool *animatedOut,
    size_t *sourceFrameCountOut
) {
    NSString *imagePath = [NSString stringWithUTF8String:path];
    NSURL *url = [NSURL fileURLWithPath:imagePath];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        printf("Could not read image file: %s\n", path);
        fflush(stdout);
        return NULL;
    }

    size_t sourceFrameCount = CGImageSourceGetCount(source);
    if (sourceFrameCount < 1) {
        printf("Image source has no frames: %s\n", path);
        fflush(stdout);
        CFRelease(source);
        return NULL;
    }

    bool animated = sourceFrameCount > 1 && !repeatFirstFrame;
    uint8_t frameCount = stillFrameCount;
    if (loopFill && sourceFrameCount > 1) {
        frameCount = maxAnimatedFrames;
    } else if (animated) {
        frameCount = (uint8_t)MIN(sourceFrameCount, (size_t)maxAnimatedFrames);
    } else if (repeatFirstFrame) {
        frameCount = maxAnimatedFrames;
    }
    if (frameCount < 1) {
        frameCount = 1;
    }

    const size_t headerLength = 256;
    const size_t frameBytes = width * height * 2;
    const size_t payloadLength = headerLength + ((size_t)frameCount * frameBytes);
    const size_t chunks = (payloadLength + 4095) / 4096;
    const size_t paddedLength = chunks * 4096;
    uint8_t *stream = malloc(paddedLength);
    if (!stream) {
        printf("Could not allocate %zu bytes for image stream.\n", paddedLength);
        fflush(stdout);
        CFRelease(source);
        return NULL;
    }

    memset(stream, 0x00, paddedLength);
    stream[0] = frameCount;
    for (uint8_t frame = 0; frame < frameCount; frame++) {
        size_t sourceIndex = loopFill && sourceFrameCount > 1 ? ((size_t)frame % sourceFrameCount) : (animated ? frame : 0);
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, sourceIndex, NULL));
        stream[1 + frame] = repeatFirstFrame ? stillFrameDelay : ((animated || loopFill) ? gifDelayByte(properties ?: @{}) : stillFrameDelay);

        CGImageRef image = CGImageSourceCreateImageAtIndex(source, sourceIndex, NULL);
        if (!image) {
            continue;
        }
        writeCGImageFrame(stream, headerLength + ((size_t)frame * frameBytes), image, width, height, fitMode, pixelFormat, pixelLayout);
        CGImageRelease(image);
    }

    CFRelease(source);
    *streamLength = paddedLength;
    if (payloadLengthOut) {
        *payloadLengthOut = payloadLength;
    }
    *chunkCount = (uint16_t)chunks;
    if (frameCountOut) {
        *frameCountOut = frameCount;
    }
    if (animatedOut) {
        *animatedOut = animated;
    }
    if (sourceFrameCountOut) {
        *sourceFrameCountOut = sourceFrameCount;
    }
    return stream;
}

static IOReturn sendScreenBulkChunkVariant(
    DeviceMonitor *monitor,
    const uint8_t *chunk,
    CFIndex length,
    uint16_t index,
    uint16_t total,
    bool prefixed,
    bool waitForStatus,
    double statusTimeoutSeconds
) {
    CFIndex reportLength = prefixed ? length + 1 : length;
    if (monitor->usagePage != 0xff68 || monitor->outputSize <= 0) {
        return kIOReturnNoDevice;
    }

    uint8_t *payload = NULL;
    const uint8_t *report = chunk;
    if (prefixed) {
        payload = calloc((size_t)reportLength, sizeof(uint8_t));
        if (!payload) {
            return kIOReturnNoMemory;
        }
        memcpy(payload + 1, chunk, (size_t)length);
        report = payload;
    } else if (monitor->outputSize < reportLength) {
        return kIOReturnNoDevice;
    }

    uint64_t beforeCounter = monitor->reportCounter;
    IOReturn result = IOHIDDeviceSetReport(
        monitor->device,
        kIOHIDReportTypeOutput,
        0,
        report,
        reportLength
    );
    bool acked = !waitForStatus;
    if (result == kIOReturnSuccess && waitForStatus) {
        CFAbsoluteTime stopAt = CFAbsoluteTimeGetCurrent() + statusTimeoutSeconds;
        while (CFAbsoluteTimeGetCurrent() < stopAt) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
            if (monitor->reportCounter != beforeCounter && monitor->lastReportLength >= 3) {
                acked = true;
                break;
            }
        }
    }

    if (total <= 16 || index == 1 || index == total || index % 16 == 0 || result != kIOReturnSuccess || (waitForStatus && !acked)) {
        printf(
            "Sent screen chunk %u/%u%s to page=0x%04x len=%ld result=0x%08x%s first16=",
            index,
            total,
            prefixed ? " prefixed" : "",
            monitor->usagePage,
            (long)reportLength,
            result,
            waitForStatus ? (acked ? " ack=yes" : " ack=no") : ""
        );
        printHex(report, reportLength < 16 ? reportLength : 16);
        if (waitForStatus && monitor->lastReportLength > 0) {
            printf(" lastInput=");
            printHex(monitor->lastReport, monitor->lastReportLength < 16 ? monitor->lastReportLength : 16);
        }
        printf("\n");
        fflush(stdout);
    }
    free(payload);
    return waitForStatus && !acked ? kIOReturnTimeout : result;
}

static void sendScreenTestUpload(
    DeviceMonitor *monitors,
    CFIndex count,
    int slot,
    bool prefixed,
    uint8_t frameCount,
    uint8_t frameDelay,
    ScreenPixelFormat pixelFormat,
    ScreenPixelLayout pixelLayout,
    bool waitForChunkStatus
) {
    DeviceMonitor *control = findMonitor(monitors, count, 0xff13);
    DeviceMonitor *bulk = findMonitor(monitors, count, 0xff68);
    if (!control || !bulk) {
        printf("Screen upload needs both 0xff13 control and 0xff68 bulk endpoints.\n");
        fflush(stdout);
        return;
    }

    size_t streamLength = 0;
    size_t payloadLength = 0;
    uint16_t chunkCount = 0;
    uint8_t *stream = createScreenTestStream(&streamLength, &payloadLength, &chunkCount, frameCount, frameDelay, pixelFormat, pixelLayout);
    if (!stream) {
        printf("Could not allocate screen test stream.\n");
        fflush(stdout);
        return;
    }

    const uint8_t beginCommand[] = {0x04, 0x18};
    uint8_t metadataCommand[10] = {0};
    metadataCommand[0] = 0x04;
    metadataCommand[1] = 0x72;
    metadataCommand[2] = (uint8_t)slot;
    metadataCommand[8] = (uint8_t)(chunkCount & 0xff);
    metadataCommand[9] = (uint8_t)(chunkCount >> 8);
    const uint8_t exitCommand[] = {0x04, 0x02};

    printf(
        "Prepared 128x128 RGB565 test upload for screen slot %d%s layout=%s%s: %u frame(s), delay %u, %zu payload bytes, %zu bytes padded into %u chunk(s).\n",
        slot,
        prefixed ? " with leading zero HID prefix" : "",
        screenPixelLayoutName(pixelLayout),
        waitForChunkStatus ? " with chunk status wait" : "",
        frameCount,
        frameDelay,
        payloadLength,
        streamLength,
        chunkCount
    );
    fflush(stdout);

    if (sendScreenControlCommandVariant(control, beginCommand, sizeof(beginCommand), "upload-begin", prefixed, true) != kIOReturnSuccess) {
        free(stream);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);

    if (sendScreenControlCommandVariant(control, metadataCommand, sizeof(metadataCommand), "upload-metadata", prefixed, true) != kIOReturnSuccess) {
        sendScreenControlCommandVariant(control, exitCommand, sizeof(exitCommand), "exit", prefixed, true);
        free(stream);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    bool previousBulkSuppress = bulk->suppressInputLog;
    bulk->suppressInputLog = true;
    for (uint16_t i = 0; i < chunkCount; i++) {
        const uint8_t *chunk = stream + ((size_t)i * 4096);
        IOReturn result = sendScreenBulkChunkVariant(bulk, chunk, 4096, (uint16_t)(i + 1), chunkCount, prefixed, waitForChunkStatus, 0.35);
        if (result != kIOReturnSuccess) {
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);
    }
    bulk->suppressInputLog = previousBulkSuppress;

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    sendScreenControlCommandVariant(control, exitCommand, sizeof(exitCommand), "exit", prefixed, true);
    free(stream);
}

static void sendScreenLayoutScanUpload(
    DeviceMonitor *monitors,
    CFIndex count,
    int slot,
    ScreenPixelFormat pixelFormat,
    double chunkDelaySeconds
) {
    DeviceMonitor *control = findMonitor(monitors, count, 0xff13);
    DeviceMonitor *bulk = findMonitor(monitors, count, 0xff68);
    if (!control || !bulk) {
        printf("Screen layout scan needs both 0xff13 control and 0xff68 bulk endpoints.\n");
        fflush(stdout);
        return;
    }

    size_t streamLength = 0;
    size_t payloadLength = 0;
    uint16_t chunkCount = 0;
    uint8_t *stream = createScreenLayoutScanStream(&streamLength, &payloadLength, &chunkCount, pixelFormat);
    if (!stream) {
        printf("Could not allocate screen layout scan stream.\n");
        fflush(stdout);
        return;
    }

    const uint8_t beginCommand[] = {0x04, 0x18};
    uint8_t metadataCommand[10] = {0};
    metadataCommand[0] = 0x04;
    metadataCommand[1] = 0x72;
    metadataCommand[2] = (uint8_t)slot;
    metadataCommand[8] = (uint8_t)(chunkCount & 0xff);
    metadataCommand[9] = (uint8_t)(chunkCount >> 8);
    const uint8_t exitCommand[] = {0x04, 0x02};

    printf(
        "Prepared layout scan for screen slot %d: payload=%zu, padded=%zu, chunks=%u.\n",
        slot,
        payloadLength,
        streamLength,
        chunkCount
    );
    fflush(stdout);

    if (sendScreenControlCommandVariant(control, beginCommand, sizeof(beginCommand), "layout-begin", false, true) != kIOReturnSuccess) {
        free(stream);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);

    if (sendScreenControlCommandVariant(control, metadataCommand, sizeof(metadataCommand), "layout-metadata", false, true) != kIOReturnSuccess) {
        sendScreenControlCommandVariant(control, exitCommand, sizeof(exitCommand), "exit", false, true);
        free(stream);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    bool previousBulkSuppress = bulk->suppressInputLog;
    bulk->suppressInputLog = true;
    for (uint16_t i = 0; i < chunkCount; i++) {
        const uint8_t *chunk = stream + ((size_t)i * 4096);
        IOReturn result = sendScreenBulkChunkVariant(bulk, chunk, 4096, (uint16_t)(i + 1), chunkCount, false, false, 0.0);
        if (result != kIOReturnSuccess) {
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, chunkDelaySeconds, false);
    }
    bulk->suppressInputLog = previousBulkSuppress;

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    sendScreenControlCommandVariant(control, exitCommand, sizeof(exitCommand), "exit", false, true);
    free(stream);
}

static void sendScreenImageUpload(
    DeviceMonitor *monitors,
    CFIndex count,
    const char *path,
    int slot,
    bool controlPrefixed,
    bool bulkPrefixed,
    uint8_t stillFrameCount,
    uint8_t stillFrameDelay,
    uint8_t maxAnimatedFrames,
    size_t width,
    size_t height,
    ScreenFitMode fitMode,
    ScreenPixelFormat pixelFormat,
    ScreenPixelLayout pixelLayout,
    bool repeatFirstFrame,
    bool loopFill,
    double chunkDelaySeconds,
    bool waitForChunkStatus
) {
    DeviceMonitor *control = findMonitor(monitors, count, 0xff13);
    DeviceMonitor *bulk = findMonitor(monitors, count, 0xff68);
    if (!control || !bulk) {
        printf("Screen image upload needs both 0xff13 control and 0xff68 bulk endpoints.\n");
        fflush(stdout);
        return;
    }

    size_t streamLength = 0;
    size_t payloadLength = 0;
    uint16_t chunkCount = 0;
    uint8_t frameCount = 0;
    bool animated = false;
    size_t sourceFrameCount = 0;
    uint8_t *stream = createScreenImageStream(
        path,
        stillFrameCount,
        stillFrameDelay,
        maxAnimatedFrames,
        width,
        height,
        fitMode,
        pixelFormat,
        pixelLayout,
        repeatFirstFrame,
        loopFill,
        &streamLength,
        &payloadLength,
        &chunkCount,
        &frameCount,
        &animated,
        &sourceFrameCount
    );
    if (!stream) {
        return;
    }

    const uint8_t beginCommand[] = {0x04, 0x18};
    uint8_t metadataCommand[10] = {0};
    metadataCommand[0] = 0x04;
    metadataCommand[1] = 0x72;
    metadataCommand[2] = (uint8_t)slot;
    metadataCommand[8] = (uint8_t)(chunkCount & 0xff);
    metadataCommand[9] = (uint8_t)(chunkCount >> 8);
    const uint8_t exitCommand[] = {0x04, 0x02};

    printf(
        "Prepared %s upload for screen slot %d%s%s%s: size=%zux%zu, sourceFrames=%zu, sending=%u, payload=%zu, padded=%zu, chunks=%u, file=%s\n",
        animated ? "animated image" : "still image",
        slot,
        controlPrefixed ? " with prefixed control" : "",
        bulkPrefixed ? " with prefixed bulk" : "",
        waitForChunkStatus ? " with chunk status wait" : "",
        width,
        height,
        sourceFrameCount,
        frameCount,
        payloadLength,
        streamLength,
        chunkCount,
        path
    );
    uint8_t previewDelayCount = frameCount > 32 ? 32 : frameCount;
    printf("Delay bytes first %u/%u frame(s)=", previewDelayCount, frameCount);
    printHex(stream + 1, previewDelayCount);
    printf("\n");
    fflush(stdout);

    if (sendScreenControlCommandVariant(control, beginCommand, sizeof(beginCommand), "image-begin", controlPrefixed, true) != kIOReturnSuccess) {
        free(stream);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    if (sendScreenControlCommandVariant(control, metadataCommand, sizeof(metadataCommand), "image-metadata", controlPrefixed, true) != kIOReturnSuccess) {
        sendScreenControlCommandVariant(control, exitCommand, sizeof(exitCommand), "exit", controlPrefixed, true);
        free(stream);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    bool ok = true;
    bool previousBulkSuppress = bulk->suppressInputLog;
    bulk->suppressInputLog = true;
    for (uint16_t i = 0; i < chunkCount; i++) {
        const uint8_t *chunk = stream + ((size_t)i * 4096);
        IOReturn result = sendScreenBulkChunkVariant(bulk, chunk, 4096, (uint16_t)(i + 1), chunkCount, bulkPrefixed, waitForChunkStatus, 0.35);
        if (result != kIOReturnSuccess) {
            ok = false;
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, chunkDelaySeconds, false);
    }
    bulk->suppressInputLog = previousBulkSuppress;

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    sendScreenControlCommandVariant(control, exitCommand, sizeof(exitCommand), "exit", controlPrefixed, true);
    printf("Screen image upload %s.\n", ok ? "completed" : "stopped after a failed chunk");
    fflush(stdout);
    free(stream);
}

static IOReturn sendScreenUSBPipeChunk(USBPipeInterface *pipeInterface, const uint8_t *chunk, UInt32 length, uint16_t index, uint16_t total) {
    IOReturn result = (*pipeInterface->interface)->WritePipe(
        pipeInterface->interface,
        pipeInterface->outputPipe,
        (void *)chunk,
        length
    );

    printf(
        "USB WritePipe screen chunk %u/%u pipe=%u len=%u result=0x%08x first16=",
        index,
        total,
        pipeInterface->outputPipe,
        length,
        result
    );
    printHex(chunk, length < 16 ? length : 16);
    printf("\n");
    fflush(stdout);
    return result;
}

static void sendScreenUSBPipeTestUpload(DeviceMonitor *monitors, CFIndex count) {
    DeviceMonitor *control = findMonitor(monitors, count, 0xff13);
    if (!control) {
        printf("USB-pipe screen upload needs the 0xff13 control endpoint.\n");
        fflush(stdout);
        return;
    }

    USBPipeInterface pipeInterface;
    if (!openUSBPipeInterface(2, false, &pipeInterface)) {
        printf("Retrying USB interface 2 with USBInterfaceOpenSeize.\n");
        fflush(stdout);
        if (!openUSBPipeInterface(2, true, &pipeInterface)) {
            return;
        }
    }

    size_t streamLength = 0;
    size_t payloadLength = 0;
    uint16_t chunkCount = 0;
    uint8_t *stream = createScreenTestStream(&streamLength, &payloadLength, &chunkCount, 1, 50, ScreenPixelRGB565LE, ScreenLayoutRowMajor);
    if (!stream) {
        printf("Could not allocate screen test stream.\n");
        fflush(stdout);
        closeUSBPipeInterface(&pipeInterface);
        return;
    }

    const uint8_t beginCommand[] = {0x04, 0x18};
    uint8_t metadataCommand[10] = {0};
    metadataCommand[0] = 0x04;
    metadataCommand[1] = 0x72;
    metadataCommand[2] = 0x01;
    metadataCommand[8] = (uint8_t)(chunkCount & 0xff);
    metadataCommand[9] = (uint8_t)(chunkCount >> 8);
    const uint8_t exitCommand[] = {0x04, 0x02};

    printf(
        "Prepared USB WritePipe 128x128 RGB565 test frame for screen slot 1: %zu payload bytes, %zu bytes padded into %u chunk(s).\n",
        payloadLength,
        streamLength,
        chunkCount
    );
    fflush(stdout);

    if (sendScreenControlCommand(control, beginCommand, sizeof(beginCommand), "usb-upload-begin") != kIOReturnSuccess) {
        free(stream);
        closeUSBPipeInterface(&pipeInterface);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    if (sendScreenControlCommand(control, metadataCommand, sizeof(metadataCommand), "usb-upload-metadata") != kIOReturnSuccess) {
        sendScreenControlCommand(control, exitCommand, sizeof(exitCommand), "exit");
        free(stream);
        closeUSBPipeInterface(&pipeInterface);
        return;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    bool ok = true;
    for (uint16_t i = 0; i < chunkCount; i++) {
        const uint8_t *chunk = stream + ((size_t)i * 4096);
        IOReturn result = sendScreenUSBPipeChunk(&pipeInterface, chunk, 4096, (uint16_t)(i + 1), chunkCount);
        if (result != kIOReturnSuccess) {
            ok = false;
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);
    }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    sendScreenControlCommand(control, exitCommand, sizeof(exitCommand), "usb-upload-exit");
    printf("USB WritePipe screen upload %s.\n", ok ? "completed" : "stopped after a failed chunk");
    fflush(stdout);
    free(stream);
    closeUSBPipeInterface(&pipeInterface);
}

static void finishSmallScreenReport(uint8_t *report, size_t length, size_t checksumIndex) {
    if (length <= checksumIndex) {
        return;
    }

    report[checksumIndex] = 0;
    uint8_t checksum = 0;
    for (size_t i = 0; i < length; i++) {
        checksum = (uint8_t)(checksum + report[i]);
    }
    report[checksumIndex] = checksum;
}

static bool waitForSmallScreenAck(DeviceMonitor *control, const uint8_t *report, size_t ackOffset, uint64_t beforeCounter) {
    for (int i = 0; i < 25; i++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        if (control->reportCounter == beforeCounter || control->lastReportLength < 3) {
            continue;
        }
        if (control->lastReport[0] == report[ackOffset] && control->lastReport[1] == report[ackOffset + 1] && control->lastReport[2] == report[ackOffset + 2]) {
            return true;
        }
    }
    return false;
}

static bool sendScreenSmallReport(DeviceMonitor *control, uint8_t *report, size_t ackOffset, size_t checksumIndex, const char *label, uint32_t index, uint32_t total) {
    if (control->usagePage != 0xff13 || control->outputSize < 64) {
        return false;
    }

    finishSmallScreenReport(report, 64, checksumIndex);
    uint64_t beforeCounter = control->reportCounter;
    IOReturn result = IOHIDDeviceSetReport(
        control->device,
        kIOHIDReportTypeOutput,
        0,
        report,
        64
    );
    bool acked = false;
    if (result == kIOReturnSuccess) {
        acked = waitForSmallScreenAck(control, report, ackOffset, beforeCounter);
    }

    if (index == 0 || index == total || index % 100 == 0 || result != kIOReturnSuccess || !acked) {
        printf(
            "Sent small screen %s %u/%u result=0x%08x ack=%s first16=",
            label,
            index,
            total,
            result,
            acked ? "yes" : "no"
        );
        printHex(report, 16);
        if (!acked && control->reportCounter != beforeCounter && control->lastReportLength > 0) {
            printf(" lastInput=");
            printHex(control->lastReport, control->lastReportLength < 16 ? control->lastReportLength : 16);
        }
        printf("\n");
        fflush(stdout);
    }

    return result == kIOReturnSuccess && acked;
}

static void sendScreenSmallTestUpload(DeviceMonitor *monitors, CFIndex count, bool prefixed) {
    DeviceMonitor *control = findMonitor(monitors, count, 0xff13);
    if (!control) {
        printf("Small screen upload needs the 0xff13 control endpoint.\n");
        fflush(stdout);
        return;
    }

    size_t streamLength = 0;
    size_t payloadLength = 0;
    uint16_t largeChunkCount = 0;
    uint8_t *stream = createScreenTestStream(&streamLength, &payloadLength, &largeChunkCount, 1, 50, ScreenPixelRGB565LE, ScreenLayoutRowMajor);
    if (!stream) {
        printf("Could not allocate screen test stream.\n");
        fflush(stdout);
        return;
    }

    const uint32_t smallPayloadBytes = 28;
    uint32_t packetCount = (uint32_t)((payloadLength + smallPayloadBytes - 1) / smallPayloadBytes);
    uint8_t report[64] = {0};
    size_t base = prefixed ? 1 : 0;
    size_t checksumIndex = base + 31;
    report[base] = 0x7f;
    report[base + 1] = 0x03;
    report[base + 2] = 0x00;
    report[base + 3] = 0x01;
    report[base + 4] = (uint8_t)(packetCount & 0xff);
    report[base + 5] = (uint8_t)((packetCount >> 8) & 0xff);
    report[base + 6] = (uint8_t)((packetCount >> 16) & 0xff);

    printf(
        "Prepared small-packet screen upload for slot 1%s: %zu payload bytes in %u packet(s).\n",
        prefixed ? " with leading zero prefix" : "",
        payloadLength,
        packetCount
    );
    fflush(stdout);

    bool previousSuppress = control->suppressInputLog;
    control->suppressInputLog = true;

    if (!sendScreenSmallReport(control, report, base, checksumIndex, "begin", 0, packetCount)) {
        printf("Small screen upload begin was not acknowledged; stopping before data packets.\n");
        fflush(stdout);
        control->suppressInputLog = previousSuppress;
        free(stream);
        return;
    }

    bool ok = true;
    for (uint32_t i = 0; i < packetCount; i++) {
        memset(report, 0, sizeof(report));
        if (i > 0xffff) {
            report[base] = (uint8_t)(0x80 | ((i >> 16) & 0x7f));
        } else {
            report[base] = 0x80;
        }
        report[base + 1] = (uint8_t)(i & 0xff);
        report[base + 2] = (uint8_t)((i >> 8) & 0xff);
        memcpy(&report[base + 3], stream + ((size_t)i * smallPayloadBytes), smallPayloadBytes);

        if (!sendScreenSmallReport(control, report, base, checksumIndex, "data", i + 1, packetCount)) {
            ok = false;
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
    }

    control->suppressInputLog = previousSuppress;
    printf("Small screen upload %s.\n", ok ? "completed with acknowledgements" : "stopped after an unacknowledged packet");
    fflush(stdout);
    free(stream);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        double seconds = secondsArgument(argc, argv);
        bool allInterfaces = allInterfacesArgument(argc, argv);
        bool viaQuery = hasArgument(argc, argv, "--via-query");
        bool batteryQuery = hasArgument(argc, argv, "--battery-query");
        bool screenExitProbe = hasArgument(argc, argv, "--screen-exit-probe");
        bool screenHandshakeProbe = hasArgument(argc, argv, "--screen-handshake-probe");
        bool screenTestUpload = hasArgument(argc, argv, "--screen-test-upload");
        bool screenPrefixedTestUpload = hasArgument(argc, argv, "--screen-test-upload-prefixed");
        bool screenLayoutScan = hasArgument(argc, argv, "--screen-layout-scan");
        bool screenUSBPipeTestUpload = hasArgument(argc, argv, "--screen-test-upload-usb");
        bool screenSmallTestUpload = hasArgument(argc, argv, "--screen-test-upload-small");
        bool screenSmallPrefixedTestUpload = hasArgument(argc, argv, "--screen-test-upload-small-prefixed");
        bool screenTimeSync = hasArgument(argc, argv, "--screen-sync-time");
        bool readFeatures = hasArgument(argc, argv, "--read-features");
        bool seizeHID = hasArgument(argc, argv, "--seize-hid");
        const char *sendOutputHex = stringArgument(argc, argv, "--send-output-hex");
        const char *sendFeatureHex = stringArgument(argc, argv, "--send-feature-hex");
        int sendPage = intArgument(argc, argv, "--send-page", -1);
        bool sendChecksum = hasArgument(argc, argv, "--send-checksum");
        int sendChecksumIndex = intArgument(argc, argv, "--send-checksum-index", -1);
        bool sendPadReport = hasArgument(argc, argv, "--send-pad-report");
        int rgbMode = intArgument(argc, argv, "--rgb-mode", -1);
        bool rgbCommitOnly = hasArgument(argc, argv, "--rgb-commit-only");
        int rgbLEDMode = intArgument(argc, argv, "--rgb-led-mode", -1);
        int rgbStandardMode = intArgument(argc, argv, "--rgb-standard-mode", -1);
        int rgbBrightness = intArgument(argc, argv, "--rgb-brightness", 5);
        int rgbSpeed = intArgument(argc, argv, "--rgb-speed", 3);
        int rgbDirection = intArgument(argc, argv, "--rgb-direction", 0);
        int rgbColorful = intArgument(argc, argv, "--rgb-colorful", 1);
        int rgbColor = intArgument(argc, argv, "--rgb-color", 0x0000ff);
        bool rgbNoCommit = hasArgument(argc, argv, "--rgb-no-commit");
        int rgbPage = intArgument(argc, argv, "--rgb-page", 0xff60);
        bool rgbReportID = hasArgument(argc, argv, "--rgb-report-id");
        bool rgbPadReport = hasArgument(argc, argv, "--rgb-pad-report");
        bool rgbStandardOutput = hasArgument(argc, argv, "--rgb-standard-output");
        int keyResponseLevel = intArgument(argc, argv, "--key-response-level", -1);
        int keyResponseFnSwitch = intArgument(argc, argv, "--key-response-fn-switch", 1);
        int keyResponseSleepTime = intArgument(argc, argv, "--key-response-sleep-time", 1);
        bool keyResponseIncludeFnLayer = hasArgument(argc, argv, "--key-response-fn-switch") || hasArgument(argc, argv, "--key-response-include-fn-layer");
        bool keyResponseIncludeSleepTime = hasArgument(argc, argv, "--key-response-sleep-time") || hasArgument(argc, argv, "--key-response-include-sleep-time");
        int keyResponsePage = intArgument(argc, argv, "--key-response-page", 0xff60);
        bool keyResponseCommit = hasArgument(argc, argv, "--key-response-commit") && !hasArgument(argc, argv, "--key-response-no-commit");
        bool keyResponseReportID = hasArgument(argc, argv, "--key-response-report-id");
        bool keyResponsePadReport = hasArgument(argc, argv, "--key-response-pad-report");
        int gameMode = intArgument(argc, argv, "--game-mode", -1);
        int gameResponseLevel = intArgument(argc, argv, "--game-response-level", 1);
        int gameFnSwitch = intArgument(argc, argv, "--game-fn-switch", 1);
        int gameSleepTime = intArgument(argc, argv, "--game-sleep-time", 1);
        int gameDisableAltTab = intArgument(argc, argv, "--game-disable-alttab", gameMode >= 0 ? gameMode : 0);
        int gameDisableAltF4 = intArgument(argc, argv, "--game-disable-altf4", gameMode >= 0 ? gameMode : 0);
        int gameDisableWin = intArgument(argc, argv, "--game-disable-win", gameMode >= 0 ? gameMode : 0);
        int gamePage = intArgument(argc, argv, "--game-page", 0xff60);
        bool gameReportID = hasArgument(argc, argv, "--game-report-id");
        bool gamePadReport = hasArgument(argc, argv, "--game-pad-report");
        const char *screenUploadImagePath = stringArgument(argc, argv, "--screen-upload-image");
        bool screenChunkAck = hasArgument(argc, argv, "--screen-chunk-ack");
        bool screenUploadPrefixed = hasArgument(argc, argv, "--screen-upload-prefixed");
        bool screenUploadControlPrefixed = screenUploadPrefixed || hasArgument(argc, argv, "--screen-upload-control-prefixed");
        bool screenUploadBulkPrefixed = screenUploadPrefixed || hasArgument(argc, argv, "--screen-upload-bulk-prefixed");
        ScreenFitMode screenFitMode = screenFitArgument(argc, argv);
        ScreenPixelFormat screenPixelFormat = screenPixelFormatArgument(argc, argv);
        ScreenPixelLayout screenPixelLayout = screenPixelLayoutArgument(argc, argv);
        bool screenRepeatFirst = hasArgument(argc, argv, "--screen-repeat-first");
        bool screenLoopFill = hasArgument(argc, argv, "--screen-loop-fill");
        double screenChunkDelaySeconds = doubleArgument(argc, argv, "--screen-chunk-delay", 0.04);
        if (screenChunkDelaySeconds < 0.005) {
            screenChunkDelaySeconds = 0.005;
        } else if (screenChunkDelaySeconds > 0.5) {
            screenChunkDelaySeconds = 0.5;
        }
        int screenSlot = intArgument(argc, argv, "--screen-slot", 1);
        if (screenSlot < 0) {
            screenSlot = 0;
        } else if (screenSlot > 255) {
            screenSlot = 255;
        }
        int screenFramesInt = intArgument(argc, argv, "--screen-frames", 1);
        if (screenFramesInt < 1) {
            screenFramesInt = 1;
        } else if (screenFramesInt > 255) {
            screenFramesInt = 255;
        }
        int screenDelayInt = intArgument(argc, argv, "--screen-delay", 50);
        if (screenDelayInt < 1) {
            screenDelayInt = 1;
        } else if (screenDelayInt > 255) {
            screenDelayInt = 255;
        }
        uint8_t screenFrames = (uint8_t)screenFramesInt;
        uint8_t screenDelay = (uint8_t)screenDelayInt;
        int screenMaxFramesInt = intArgument(argc, argv, "--screen-max-frames", 32);
        if (screenMaxFramesInt < 1) {
            screenMaxFramesInt = 1;
        } else if (screenMaxFramesInt > 255) {
            screenMaxFramesInt = 255;
        }
        uint8_t screenMaxFrames = (uint8_t)screenMaxFramesInt;
        int screenWidthInt = intArgument(argc, argv, "--screen-width", 128);
        int screenHeightInt = intArgument(argc, argv, "--screen-height", 128);
        if (screenWidthInt < 1) {
            screenWidthInt = 128;
        }
        if (screenHeightInt < 1) {
            screenHeightInt = 128;
        }
        size_t screenWidth = (size_t)screenWidthInt;
        size_t screenHeight = (size_t)screenHeightInt;
        bool onlyDongle = dongleArgument(argc, argv);
        bool onlyWired = wiredArgument(argc, argv);

        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        if (!manager) {
            fprintf(stderr, "Could not create IOHIDManager.\n");
            return 1;
        }

        if (allInterfaces) {
            CFMutableArrayRef matches = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
            if (!onlyWired) {
                CFMutableDictionaryRef dict = matchingDictionary(kDongleVendorID, kDongleProductID, -1);
                CFArrayAppendValue(matches, dict);
                CFRelease(dict);
            }
            if (!onlyDongle) {
                CFMutableDictionaryRef dict = matchingDictionary(kWiredVendorID, kWiredProductID, -1);
                CFArrayAppendValue(matches, dict);
                CFRelease(dict);
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches);
            CFRelease(matches);
        } else {
            CFMutableArrayRef matches = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
            if (!onlyWired) {
                appendMatches(matches, kDongleMatches, sizeof(kDongleMatches) / sizeof(kDongleMatches[0]));
            }
            if (!onlyDongle) {
                if (screenUSBPipeTestUpload) {
                    appendMatches(matches, kWiredControlMatches, sizeof(kWiredControlMatches) / sizeof(kWiredControlMatches[0]));
                } else {
                    appendMatches(matches, kWiredMatches, sizeof(kWiredMatches) / sizeof(kWiredMatches[0]));
                }
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches);
            CFRelease(matches);
        }

        IOReturn openResult = IOHIDManagerOpen(manager, seizeHID ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone);
        if (openResult != kIOReturnSuccess) {
            fprintf(stderr, "Failed to open HID manager: 0x%08x\n", openResult);
            CFRelease(manager);
            return 1;
        }

        CFSetRef deviceSet = IOHIDManagerCopyDevices(manager);
        if (!deviceSet || CFSetGetCount(deviceSet) == 0) {
            printf("No Aula F75 dongle HID devices matched.\n");
            if (deviceSet) {
                CFRelease(deviceSet);
            }
            IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
            CFRelease(manager);
            return 2;
        }

        CFIndex count = CFSetGetCount(deviceSet);
        IOHIDDeviceRef *devices = calloc((size_t)count, sizeof(IOHIDDeviceRef));
        DeviceMonitor *monitors = calloc((size_t)count, sizeof(DeviceMonitor));
        CFSetGetValues(deviceSet, (const void **)devices);
        int exitStatus = 0;

        printf("Matched %ld HID device(s). Listening for %.1fs. Touch the keyboard or use its battery shortcut if it has one.\n", (long)count, seconds);
        for (CFIndex i = 0; i < count; i++) {
            DeviceMonitor *monitor = &monitors[i];
            monitor->device = devices[i];
            stringProperty(monitor->device, CFSTR(kIOHIDProductKey), monitor->product, sizeof(monitor->product), "Unknown");
            monitor->usagePage = intProperty(monitor->device, CFSTR(kIOHIDPrimaryUsagePageKey), -1);
            monitor->usage = intProperty(monitor->device, CFSTR(kIOHIDPrimaryUsageKey), -1);
            monitor->inputSize = intProperty(monitor->device, CFSTR(kIOHIDMaxInputReportSizeKey), 64);
            monitor->outputSize = intProperty(monitor->device, CFSTR(kIOHIDMaxOutputReportSizeKey), 0);
            monitor->featureSize = intProperty(monitor->device, CFSTR(kIOHIDMaxFeatureReportSizeKey), 0);
            if (monitor->inputSize < 1) {
                monitor->inputSize = 1;
            }
            monitor->buffer = calloc((size_t)monitor->inputSize, sizeof(uint8_t));

            printf(
                " - %s usagePage=0x%04x usage=0x%02x in=%d out=%d feature=%d\n",
                monitor->product,
                monitor->usagePage,
                monitor->usage,
                monitor->inputSize,
                monitor->outputSize,
                monitor->featureSize
            );

            IOHIDDeviceRegisterInputReportCallback(
                monitor->device,
                monitor->buffer,
                monitor->inputSize,
                inputCallback,
                monitor
            );
            IOHIDDeviceScheduleWithRunLoop(monitor->device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        }
        fflush(stdout);

        if (viaQuery) {
            for (CFIndex i = 0; i < count; i++) {
                if (monitors[i].usagePage == 0xff60) {
                    sendViaProtocolQuery(&monitors[i]);
                }
            }
        }

        if (batteryQuery) {
            for (CFIndex i = 0; i < count; i++) {
                sendBatteryQuery(&monitors[i]);
            }
        }

        if (sendOutputHex) {
            sendRawHexReports(monitors, count, sendPage, kIOHIDReportTypeOutput, sendOutputHex, sendChecksum, sendChecksumIndex, sendPadReport);
        }

        if (sendFeatureHex) {
            sendRawHexReports(monitors, count, sendPage, kIOHIDReportTypeFeature, sendFeatureHex, sendChecksum, sendChecksumIndex, sendPadReport);
        }

        if (rgbMode >= 0 && !sendWirelessRGBModeReports(monitors, count, rgbMode)) {
            exitStatus = 3;
        }

        if (rgbCommitOnly && !sendWirelessRGBCommitReportsVariant(monitors, count, rgbPage, rgbReportID, rgbPadReport)) {
            exitStatus = 3;
        }

        if (rgbLEDMode >= 0 && !sendWirelessRGBLEDModeReports(monitors, count, rgbLEDMode, rgbBrightness, rgbSpeed, rgbDirection, rgbColorful, rgbColor, !rgbNoCommit, rgbPage, rgbReportID, rgbPadReport)) {
            exitStatus = 3;
        }

        if (rgbStandardMode >= 0 && !sendWirelessRGBStandardModeReports(monitors, count, rgbStandardMode, rgbBrightness, rgbSpeed, rgbDirection, rgbColorful, rgbColor, !rgbNoCommit, rgbPage, rgbStandardOutput, rgbReportID)) {
            exitStatus = 3;
        }

        if (keyResponseLevel >= 0 && !sendWirelessKeyResponseReports(monitors, count, keyResponseLevel, keyResponseFnSwitch, keyResponseSleepTime, keyResponseIncludeFnLayer, keyResponseIncludeSleepTime, keyResponseCommit, keyResponsePage, keyResponseReportID, keyResponsePadReport)) {
            exitStatus = 3;
        }

        if (gameMode >= 0 && !sendWirelessGameModeReports(monitors, count, gameMode, gameResponseLevel, gameFnSwitch, gameSleepTime, gameDisableAltTab, gameDisableAltF4, gameDisableWin, gamePage, gameReportID, gamePadReport)) {
            exitStatus = 3;
        }

        if (screenExitProbe) {
            for (CFIndex i = 0; i < count; i++) {
                sendScreenExitProbe(&monitors[i]);
            }
        }

        if (screenHandshakeProbe) {
            for (CFIndex i = 0; i < count; i++) {
                sendScreenHandshakeProbe(&monitors[i]);
            }
        }

        if (screenTestUpload) {
            sendScreenTestUpload(monitors, count, screenSlot, false, screenFrames, screenDelay, screenPixelFormat, screenPixelLayout, screenChunkAck);
        }

        if (screenPrefixedTestUpload) {
            sendScreenTestUpload(monitors, count, screenSlot, true, screenFrames, screenDelay, screenPixelFormat, screenPixelLayout, screenChunkAck);
        }

        if (screenLayoutScan) {
            sendScreenLayoutScanUpload(monitors, count, screenSlot, screenPixelFormat, screenChunkDelaySeconds);
        }

        if (screenUploadImagePath) {
            sendScreenImageUpload(monitors, count, screenUploadImagePath, screenSlot, screenUploadControlPrefixed, screenUploadBulkPrefixed, screenFrames, screenDelay, screenMaxFrames, screenWidth, screenHeight, screenFitMode, screenPixelFormat, screenPixelLayout, screenRepeatFirst, screenLoopFill, screenChunkDelaySeconds, screenChunkAck);
        }

        if (screenUSBPipeTestUpload) {
            sendScreenUSBPipeTestUpload(monitors, count);
        }

        if (screenSmallTestUpload) {
            sendScreenSmallTestUpload(monitors, count, false);
        }

        if (screenSmallPrefixedTestUpload) {
            sendScreenSmallTestUpload(monitors, count, true);
        }

        if (screenTimeSync) {
            sendScreenTimeSync(monitors, count);
        }

        if (readFeatures) {
            for (CFIndex i = 0; i < count; i++) {
                readFeatureReports(&monitors[i]);
            }
        }

        CFAbsoluteTime stopAt = CFAbsoluteTimeGetCurrent() + seconds;
        while (CFAbsoluteTimeGetCurrent() < stopAt) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        }

        for (CFIndex i = 0; i < count; i++) {
            IOHIDDeviceUnscheduleFromRunLoop(monitors[i].device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            free(monitors[i].buffer);
        }

        free(monitors);
        free(devices);
        CFRelease(deviceSet);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        printf("Done.\n");
        return exitStatus;
    }
    return 0;
}
