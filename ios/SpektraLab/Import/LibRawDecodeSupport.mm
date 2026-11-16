#import "LibRawDecodeSupport.h"

#include "io/raw_decoder.hpp"
#include <libraw/libraw.h>

#include <array>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

static thread_local std::string gLastError;

struct SPKLibRawFrame {
    std::vector<float> pixels;
};

const char *SPKLibRawLastError(void) {
    return gLastError.c_str();
}

namespace {

void center_crop(std::vector<float> &pixels, uint32_t &width, uint32_t &height,
                 double aspect, double targetAspect) {
    if (width <= 0 || height <= 0) return;
    if (targetAspect <= 0) {
        if (aspect <= 0) return;
        const double sourceAspect = double(width) / double(height);
        targetAspect = sourceAspect >= 1.0 ? aspect : 1.0 / aspect;
    }
    const double sourceAspect = double(width) / double(height);
    uint32_t cropWidth = width, cropHeight = height;
    if (sourceAspect > targetAspect) {
        cropWidth = std::max<uint32_t>(1, uint32_t(std::llround(height * targetAspect)));
    } else if (sourceAspect < targetAspect) {
        cropHeight = std::max<uint32_t>(1, uint32_t(std::llround(width / targetAspect)));
    }
    cropWidth = std::min(cropWidth, width);
    cropHeight = std::min(cropHeight, height);
    if (cropWidth == width && cropHeight == height) return;
    const uint32_t x = (width - cropWidth) / 2;
    const uint32_t y = (height - cropHeight) / 2;
    // Work in place so a full-resolution export does not hold the complete
    // source and a second cropped frame at the same time.
    for (uint32_t row = 0; row < cropHeight; ++row) {
        const std::size_t from = (std::size_t(y + row) * width + x) * 3;
        const std::size_t to = std::size_t(row) * cropWidth * 3;
        std::memmove(pixels.data() + to, pixels.data() + from,
                     std::size_t(cropWidth) * 3 * sizeof(float));
    }
    pixels.resize(std::size_t(cropWidth) * cropHeight * 3);
    pixels.shrink_to_fit();
    width = cropWidth;
    height = cropHeight;
}

std::vector<float> resample(const std::vector<float> &source,
                            NSInteger width, NSInteger height,
                            NSInteger maxLongEdge) {
    const NSInteger longEdge = std::max(width, height);
    if (maxLongEdge <= 0 || longEdge <= maxLongEdge) return {};

    const double scale = double(maxLongEdge) / double(longEdge);
    const NSInteger targetWidth = std::max<NSInteger>(1, std::llround(width * scale));
    const NSInteger targetHeight = std::max<NSInteger>(1, std::llround(height * scale));
    std::vector<float> output(std::size_t(targetWidth) * targetHeight * 3);

    const double xStep = double(width) / double(targetWidth);
    const double yStep = double(height) / double(targetHeight);
    for (NSInteger y = 0; y < targetHeight; ++y) {
        const double sourceY = (y + 0.5) * yStep - 0.5;
        const NSInteger y0 = std::clamp<NSInteger>(NSInteger(std::floor(sourceY)), 0, height - 1);
        const NSInteger y1 = std::min<NSInteger>(y0 + 1, height - 1);
        const float fy = float(std::clamp(sourceY - y0, 0.0, 1.0));
        for (NSInteger x = 0; x < targetWidth; ++x) {
            const double sourceX = (x + 0.5) * xStep - 0.5;
            const NSInteger x0 = std::clamp<NSInteger>(NSInteger(std::floor(sourceX)), 0, width - 1);
            const NSInteger x1 = std::min<NSInteger>(x0 + 1, width - 1);
            const float fx = float(std::clamp(sourceX - x0, 0.0, 1.0));

            const std::size_t i00 = (std::size_t(y0) * width + x0) * 3;
            const std::size_t i10 = (std::size_t(y0) * width + x1) * 3;
            const std::size_t i01 = (std::size_t(y1) * width + x0) * 3;
            const std::size_t i11 = (std::size_t(y1) * width + x1) * 3;
            const std::size_t out = (std::size_t(y) * targetWidth + x) * 3;
            for (int channel = 0; channel < 3; ++channel) {
                const float top = source[i00 + channel] * (1 - fx) + source[i10 + channel] * fx;
                const float bottom = source[i01 + channel] * (1 - fx) + source[i11 + channel] * fx;
                output[out + channel] = top * (1 - fy) + bottom * fy;
            }
        }
    }
    return output;
}

}  // namespace

SPKLibRawFrameRef SPKLibRawDecode(NSData *data,
                                  NSString *filenameExtension,
                                  NSInteger maxLongEdge,
                                  double aspect,
                                  double targetAspect,
                                  NSInteger *width,
                                  NSInteger *height) {
    gLastError.clear();
    if (data.length == 0) {
        gLastError = "RAW file is empty";
        return nil;
    }

    NSString *extension = filenameExtension.length > 0 ? filenameExtension : @"raw";
    NSString *temporary = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"spektralab-%@.%@",
                                                                  NSUUID.UUID.UUIDString,
                                                                  extension]];
    NSURL *url = [NSURL fileURLWithPath:temporary];
    if (![data writeToURL:url options:NSDataWritingAtomic error:nil]) {
        gLastError = "could not stage the RAW file for decoding";
        return nil;
    }

    spk::io::DecodedRaw decoded;
    std::string error;
    bool ok = spk::io::decode_raw_compatible(url.fileSystemRepresentation, decoded, error);
    // A file with no as-shot white balance (Mamiya ZD, some old backs): the engine's decoder requires one.
    // LibRaw directly, with the camera's daylight balance (derived from its colour matrix), linear ProPhoto
    // like the engine's output. shortcut: no highlight headroom here (clips at white); fine for these few files.
    if (!ok && error.find("white balance") != std::string::npos) {
        auto raw = std::make_unique<LibRaw>();
        auto &p = raw->imgdata.params;
        p.output_color = 4; p.output_bps = 16; p.gamm[0] = p.gamm[1] = 1.0;
        p.no_auto_bright = 1; p.use_camera_wb = 0; p.use_camera_matrix = 1; p.user_qual = 3; p.highlight = 0;
        libraw_processed_image_t *image = nullptr;
        int status = 0;
        if ((status = raw->open_file(url.fileSystemRepresentation)) == LIBRAW_SUCCESS) {
            const float *pre = raw->imgdata.color.pre_mul;
            for (int c = 0; c < 4; ++c) p.user_mul[c] = pre[c] > 0 ? pre[c] : pre[1];
            if ((status = raw->unpack()) == LIBRAW_SUCCESS && (status = raw->dcraw_process()) == LIBRAW_SUCCESS)
                image = raw->dcraw_make_mem_image(&status);
        }
        if (image && image->type == LIBRAW_IMAGE_BITMAP && image->colors == 3 && image->bits == 16) {
            const size_t n = size_t(image->width) * image->height * 3;
            const auto *px = reinterpret_cast<const uint16_t *>(image->data);
            decoded.rgb.resize(n);
            for (size_t i = 0; i < n; ++i) decoded.rgb[i] = px[i] / 65535.0f;
            decoded.width = image->width;
            decoded.height = image->height;
            error.clear();
            ok = true;
        } else {
            error = std::string("RAW (daylight balance): ") + libraw_strerror(status);
        }
        if (image) LibRaw::dcraw_clear_mem(image);
    }
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    if (!ok) {
        gLastError = error.empty() ? "LibRaw could not decode this file" : error;
        return nil;
    }
    if (decoded.rgb.empty() || decoded.width == 0 || decoded.height == 0) {
        gLastError = "LibRaw returned an empty frame";
        return nil;
    }

    center_crop(decoded.rgb, decoded.width, decoded.height, aspect, targetAspect);

    std::vector<float> reduced = resample(decoded.rgb, decoded.width, decoded.height, maxLongEdge);
    const bool didResample = !reduced.empty();
    const NSInteger resolvedWidth = didResample
        ? std::max<NSInteger>(1, std::llround(decoded.width
            * (double(maxLongEdge) / double(std::max(decoded.width, decoded.height)))))
        : decoded.width;
    const NSInteger resolvedHeight = didResample
        ? std::max<NSInteger>(1, std::llround(decoded.height
            * (double(maxLongEdge) / double(std::max(decoded.width, decoded.height)))))
        : decoded.height;

    auto *result = new SPKLibRawFrame{
        didResample ? std::move(reduced) : std::move(decoded.rgb)
    };

    if (width) *width = resolvedWidth;
    if (height) *height = resolvedHeight;
    return result;
}

const float *SPKLibRawFramePixels(SPKLibRawFrameRef frame) {
    if (!frame) return nullptr;
    auto *decoded = static_cast<SPKLibRawFrame *>(frame);
    return decoded->pixels.empty() ? nullptr : decoded->pixels.data();
}

void SPKLibRawFrameFree(SPKLibRawFrameRef frame) {
    delete static_cast<SPKLibRawFrame *>(frame);
}
