const std = @import("std");

pub const Error = error{
    InvalidPrivateKey,
    SigningFailed,
    InvalidSignature,
} || std.mem.Allocator.Error;

const max_modulus_bits = 4096;
const Modulus = std.crypto.ff.Modulus(max_modulus_bits);
const Sha256 = std.crypto.hash.sha2.Sha256;
const digest_info_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

const ParsedKey = struct {
    modulus: []const u8,
    public_exponent: []const u8,
    private_exponent: []const u8,
};

pub fn signRs256Alloc(
    allocator: std.mem.Allocator,
    private_key_pem: []const u8,
    message: []const u8,
) Error![]const u8 {
    const der = try pemDerAlloc(allocator, private_key_pem);
    defer {
        std.crypto.secureZero(u8, der);
        allocator.free(der);
    }
    const key = try parsePrivateKey(der, private_key_pem);
    if (key.modulus.len < 256 or key.modulus.len > max_modulus_bits / 8) return error.InvalidPrivateKey;

    const encoded_message = try allocator.alloc(u8, key.modulus.len);
    defer {
        std.crypto.secureZero(u8, encoded_message);
        allocator.free(encoded_message);
    }
    try encodePkcs1v15Sha256(encoded_message, message);

    const modulus = Modulus.fromBytes(key.modulus, .big) catch return error.InvalidPrivateKey;
    const input = Modulus.Fe.fromBytes(modulus, encoded_message, .big) catch return error.SigningFailed;
    const output = modulus.powWithEncodedExponent(input, key.private_exponent, .big) catch return error.SigningFailed;
    const signature = try allocator.alloc(u8, key.modulus.len);
    errdefer allocator.free(signature);
    output.toBytes(signature, .big) catch return error.SigningFailed;
    return signature;
}

pub fn verifyRs256(private_key_pem: []const u8, message: []const u8, signature: []const u8) Error!void {
    const allocator = std.heap.page_allocator;
    const der = pemDerAlloc(allocator, private_key_pem) catch return error.InvalidPrivateKey;
    defer {
        std.crypto.secureZero(u8, der);
        allocator.free(der);
    }
    const key = try parsePrivateKey(der, private_key_pem);
    const public_key = std.crypto.Certificate.rsa.PublicKey.fromBytes(key.public_exponent, key.modulus) catch {
        return error.InvalidPrivateKey;
    };

    switch (signature.len) {
        256 => {
            var bytes: [256]u8 = undefined;
            @memcpy(&bytes, signature);
            std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(256, bytes, message, public_key, Sha256) catch {
                return error.InvalidSignature;
            };
        },
        384 => {
            var bytes: [384]u8 = undefined;
            @memcpy(&bytes, signature);
            std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(384, bytes, message, public_key, Sha256) catch {
                return error.InvalidSignature;
            };
        },
        512 => {
            var bytes: [512]u8 = undefined;
            @memcpy(&bytes, signature);
            std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(512, bytes, message, public_key, Sha256) catch {
                return error.InvalidSignature;
            };
        },
        else => return error.InvalidSignature,
    }
}

fn encodePkcs1v15Sha256(output: []u8, message: []const u8) Error!void {
    const trailer_len = digest_info_prefix.len + Sha256.digest_length;
    if (output.len < trailer_len + 11) return error.InvalidPrivateKey;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(message, &digest, .{});

    const separator = output.len - trailer_len - 1;
    output[0] = 0;
    output[1] = 1;
    @memset(output[2..separator], 0xff);
    output[separator] = 0;
    @memcpy(output[separator + 1 ..][0..digest_info_prefix.len], &digest_info_prefix);
    @memcpy(output[separator + 1 + digest_info_prefix.len ..], &digest);
}

fn pemDerAlloc(allocator: std.mem.Allocator, pem: []const u8) Error![]u8 {
    const pkcs8_begin = "-----BEGIN PRIVATE KEY-----";
    const pkcs8_end = "-----END PRIVATE KEY-----";
    const pkcs1_begin = "-----BEGIN RSA PRIVATE KEY-----";
    const pkcs1_end = "-----END RSA PRIVATE KEY-----";
    const bounds = if (std.mem.indexOf(u8, pem, pkcs8_begin)) |start|
        .{ start + pkcs8_begin.len, std.mem.indexOfPos(u8, pem, start + pkcs8_begin.len, pkcs8_end) orelse return error.InvalidPrivateKey }
    else if (std.mem.indexOf(u8, pem, pkcs1_begin)) |start|
        .{ start + pkcs1_begin.len, std.mem.indexOfPos(u8, pem, start + pkcs1_begin.len, pkcs1_end) orelse return error.InvalidPrivateKey }
    else
        return error.InvalidPrivateKey;

    var encoded = std.ArrayList(u8).empty;
    defer {
        std.crypto.secureZero(u8, encoded.items);
        encoded.deinit(allocator);
    }
    for (pem[bounds[0]..bounds[1]]) |byte| {
        if (!std.ascii.isWhitespace(byte)) try encoded.append(allocator, byte);
    }
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded.items) catch return error.InvalidPrivateKey;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded.items) catch return error.InvalidPrivateKey;
    return decoded;
}

fn parsePrivateKey(der: []const u8, pem: []const u8) Error!ParsedKey {
    const rsa_der = if (std.mem.indexOf(u8, pem, "-----BEGIN RSA PRIVATE KEY-----") != null)
        der
    else blk: {
        const outer = try parseElement(der, 0, .sequence);
        const version = try parseElement(der, outer.start, .integer);
        const algorithm = try parseElement(der, version.end, .sequence);
        const private_key = try parseElement(der, algorithm.end, .octet_string);
        break :blk der[private_key.start..private_key.end];
    };

    const sequence = try parseElement(rsa_der, 0, .sequence);
    const version = try parseElement(rsa_der, sequence.start, .integer);
    const modulus = try parseElement(rsa_der, version.end, .integer);
    const public_exponent = try parseElement(rsa_der, modulus.end, .integer);
    const private_exponent = try parseElement(rsa_der, public_exponent.end, .integer);
    return .{
        .modulus = try positiveInteger(rsa_der[modulus.start..modulus.end]),
        .public_exponent = try positiveInteger(rsa_der[public_exponent.start..public_exponent.end]),
        .private_exponent = try positiveInteger(rsa_der[private_exponent.start..private_exponent.end]),
    };
}

const Tag = enum(u8) {
    integer = 2,
    octet_string = 4,
    sequence = 16,
};

const Element = struct {
    start: usize,
    end: usize,
};

fn parseElement(bytes: []const u8, index: usize, expected: Tag) Error!Element {
    if (index + 2 > bytes.len) return error.InvalidPrivateKey;
    const identifier = bytes[index];
    if (identifier & 0x1f != @intFromEnum(expected)) return error.InvalidPrivateKey;
    var cursor = index + 1;
    const first_length = bytes[cursor];
    cursor += 1;
    const length: usize = if (first_length & 0x80 == 0)
        first_length
    else length: {
        const count: usize = first_length & 0x7f;
        if (count == 0 or count > @sizeOf(usize) or cursor + count > bytes.len) return error.InvalidPrivateKey;
        var value: usize = 0;
        for (bytes[cursor .. cursor + count]) |byte| value = std.math.shl(usize, value, 8) | byte;
        cursor += count;
        break :length value;
    };
    const end = std.math.add(usize, cursor, length) catch return error.InvalidPrivateKey;
    if (end > bytes.len) return error.InvalidPrivateKey;
    return .{ .start = cursor, .end = end };
}

fn positiveInteger(bytes: []const u8) Error![]const u8 {
    if (bytes.len == 0 or bytes[0] & 0x80 != 0) return error.InvalidPrivateKey;
    var value = bytes;
    while (value.len > 1 and value[0] == 0) value = value[1..];
    return value;
}
