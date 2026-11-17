// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "linear_backing_impl.h"

static void require(BOOL ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static void completed(id<MTLCommandBuffer> cb) {
    [cb commit]; [cb waitUntilCompleted];
    require(cb.status == MTLCommandBufferStatusCompleted && !cb.error, cb.error.localizedDescription.UTF8String ?: "GPU command completion");
}

static void clear_texture(id<MTLCommandBuffer> cb, id<MTLTexture> texture) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
    require(encoder != nil, "real render encoder over aligned texture");
    [encoder endEncoding];
}

static void run_case(id<MTLDevice> device, id<MTLCommandQueue> queue, MTLPixelFormat format,
                     NSUInteger width, NSUInteger height, NSUInteger row, NSUInteger offset, NSUInteger bpp) {
    NSUInteger bytes = width * bpp, length = offset + row * height + 17;
    id<MTLBuffer> guest = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    require(guest != nil, "guest buffer allocation");
    memset(guest.contents, 0xa5, length);
    for (NSUInteger y = 0; y < height; y++)
        for (NSUInteger x = 0; x < bytes; x++) ((uint8_t *)guest.contents)[offset + y * row + x] = (uint8_t)(x + y * 13);
    HvLinearBacking *backing = make_linear_backing(device, bytes, height);
    require(backing != nil, "aligned backing allocation");
    MTLTextureDescriptor *description = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    description.resourceOptions = backing->buffer.resourceOptions;
    description.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [backing->buffer newTextureWithDescriptor:description offset:0 bytesPerRow:backing->row];
    require(texture != nil, "aligned linear texture allocation");
    id<MTLBlitCommandEncoder> blit = nil;
    id<MTLCommandBuffer> upload = [queue commandBuffer];
    require(copy_linear_rows(device, upload, &blit, guest, offset, row, backing, NO), "production upload encoding");
    [blit endEncoding]; completed(upload);
    for (NSUInteger y = 0; y < height; y++)
        require(!memcmp((uint8_t *)guest.contents + offset + y * row,
                        (uint8_t *)backing->buffer.contents + y * backing->row, bytes), "packed guest pixels uploaded");

    /* An independently created alias renders into the same backing. */
    id<MTLTexture> alias = [texture newTextureViewWithPixelFormat:format];
    require(alias != nil && alias.buffer == texture.buffer, "texture alias shares backing");
    id<MTLCommandBuffer> draw = [queue commandBuffer];
    clear_texture(draw, alias);
    blit = nil;
    require(copy_linear_rows(device, draw, &blit, guest, offset, row, backing, YES), "production GPU writeback encoding");
    [blit endEncoding];
    /* Queue the next upload before the preceding GPU writeback completes. */
    [draw commit];
    HvLinearBacking *next = make_linear_backing(device, bytes, height);
    id<MTLCommandBuffer> next_frame = [queue commandBuffer];
    blit = nil;
    require(copy_linear_rows(device, next_frame, &blit, guest, offset, row, next, NO), "next queued frame upload");
    [blit endEncoding]; completed(next_frame);
    require(draw.status == MTLCommandBufferStatusCompleted && !draw.error, "prior render completed");
    uint8_t pixel[8] = {0};
    if (format == MTLPixelFormatBGRA8Unorm) pixel[2] = pixel[3] = 255;
    else if (format == MTLPixelFormatRGBA16Float) { uint16_t p[4] = {0x3c00, 0, 0, 0x3c00}; memcpy(pixel, p, 8); }
    else pixel[0] = 255;
    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            require(!memcmp((uint8_t *)guest.contents + offset + y * row + x * bpp, pixel, bpp), "rendered pixels reach packed guest memory");
            require(!memcmp((uint8_t *)next->buffer.contents + y * next->row + x * bpp, pixel, bpp), "queued upload sees new GPU output");
        }
        for (NSUInteger x = bytes; x < row; x++)
            require(((uint8_t *)guest.contents)[offset + y * row + x] == 0xa5, "writeback preserves guest row padding");
    }
    for (NSUInteger y = 0; y < height; y++) memset((uint8_t *)guest.contents + offset + y * row, 0x36, bytes);
    blit = nil;
    id<MTLCommandBuffer> changed = [queue commandBuffer];
    require(copy_linear_rows(device, changed, &blit, guest, offset, row, backing, NO), "second CPU update encoding");
    [blit endEncoding]; completed(changed);
    for (NSUInteger y = 0; y < height; y++)
        require(!memcmp((uint8_t *)guest.contents + offset + y * row,
                        (uint8_t *)backing->buffer.contents + y * backing->row, bytes), "later CPU writes refresh the same texture");
    printf("PASS format=%lu width=%lu height=%lu guest-row=%lu guest-offset=%lu host-row=%lu\n",
           (unsigned long)format, (unsigned long)width, (unsigned long)height, (unsigned long)row,
           (unsigned long)offset, (unsigned long)backing->row);
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "a real Metal device is required");
    printf("Metal device: %s\n", device.name.UTF8String);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    run_case(device, queue, MTLPixelFormatBGRA8Unorm, 24, 7, 96, 0, 4);
    run_case(device, queue, MTLPixelFormatBGRA8Unorm, 40, 9, 160, 16, 4);
    run_case(device, queue, MTLPixelFormatRGBA16Float, 14, 11, 112, 0, 8);
    run_case(device, queue, MTLPixelFormatRGBA16Float, 36, 8, 288, 32, 8);
    run_case(device, queue, MTLPixelFormatRGBA16Float, 140, 5, 1120, 0, 8);
    run_case(device, queue, MTLPixelFormatR8Unorm, 13, 3, 17, 1, 1);
    run_case(device, queue, MTLPixelFormatRGBA16Float, 1920, 1440, 15360, 0, 8);
    require(make_linear_backing(device, NSUIntegerMax, 5) == nil, "oversized backing refused");
    puts("PASS: real render, texture alias, packed writeback, queued frame ordering, repeated CPU upload, byte-copy kernel and size rejection");
    return 0;
} }
