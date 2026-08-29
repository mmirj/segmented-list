const std = @import("std");
const builtin = @import("builtin");
const SegmentedList = @import("segmented_list").SegmentedList;

const element_count = 1_000_000;

const Implementation = enum { segmented_list, array_list, memory_pool };

const implementations = [_]Implementation{
    .segmented_list,
    .array_list,
    .memory_pool,
};
const repetition_count = implementations.len * 3;

const Sample = struct {
    checksum: u64,
    duration_ns: u128,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try warm_up(gpa);

    var total_ns = [_]u128{0} ** implementations.len;
    for (0..repetition_count) |repetition| {
        var checksums: [implementations.len]u64 = undefined;
        for (0..implementations.len) |offset| {
            const order_index = (repetition + offset) % implementations.len;
            const implementation = implementations[order_index];
            const sample = try measure(io, gpa, implementation, element_count);
            const implementation_index = @intFromEnum(implementation);
            checksums[implementation_index] = sample.checksum;
            total_ns[implementation_index] += sample.duration_ns;
        }
        try validate_checksums(checksums);
    }

    try stdout.print(
        "{s}, std.heap.smp_allocator, {d} u64 elements, {d} repetitions\n" ++
            "append + indexed scan + release; SegmentedList inline capacity 0\n\n",
        .{ @tagName(builtin.mode), element_count, repetition_count },
    );
    for (implementations) |implementation| {
        try write_result(stdout, implementation, total_ns[@intFromEnum(implementation)]);
    }
    try stdout.flush();
}

fn warm_up(allocator: std.mem.Allocator) !void {
    var checksums: [implementations.len]u64 = undefined;
    for (implementations) |implementation| {
        checksums[@intFromEnum(implementation)] = try run(
            allocator,
            implementation,
            element_count,
        );
    }
    try validate_checksums(checksums);
}

fn measure(
    io: std.Io,
    allocator: std.mem.Allocator,
    implementation: Implementation,
    count: usize,
) !Sample {
    const start = std.Io.Clock.awake.now(io);
    const checksum = try run(allocator, implementation, count);
    const duration = start.durationTo(std.Io.Clock.awake.now(io));
    std.mem.doNotOptimizeAway(checksum);
    return .{ .checksum = checksum, .duration_ns = @intCast(duration.nanoseconds) };
}

fn run(allocator: std.mem.Allocator, implementation: Implementation, count: usize) !u64 {
    return switch (implementation) {
        .segmented_list => run_segmented_list(allocator, count),
        .array_list => run_array_list(allocator, count),
        .memory_pool => run_memory_pool(allocator, count),
    };
}

fn run_segmented_list(allocator: std.mem.Allocator, count: usize) !u64 {
    var list: SegmentedList(u64, 0) = .empty;
    defer list.deinit(allocator);
    for (0..count) |index| try list.append(allocator, @intCast(index));

    var checksum: u64 = 0;
    for (0..list.len) |index| checksum +%= list.at(index).*;
    return checksum;
}

fn run_array_list(allocator: std.mem.Allocator, count: usize) !u64 {
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(allocator);
    for (0..count) |index| try list.append(allocator, @intCast(index));

    var checksum: u64 = 0;
    for (list.items) |item| checksum +%= item;
    return checksum;
}

fn run_memory_pool(allocator: std.mem.Allocator, count: usize) !u64 {
    var pool: std.heap.MemoryPool(u64) = .empty;
    defer pool.deinit(allocator);

    var pointers: std.ArrayList(*u64) = .empty;
    defer pointers.deinit(allocator);

    for (0..count) |index| {
        const pointer = try pool.create(allocator);
        pointer.* = @intCast(index);
        try pointers.append(allocator, pointer);
    }

    var checksum: u64 = 0;
    for (pointers.items) |pointer| checksum +%= pointer.*;
    return checksum;
}

fn validate_checksums(checksums: [implementations.len]u64) !void {
    for (checksums[1..]) |checksum| {
        if (checksum != checksums[0]) return error.ChecksumMismatch;
    }
}

fn write_result(
    writer: *std.Io.Writer,
    implementation: Implementation,
    total_ns: u128,
) std.Io.Writer.Error!void {
    const total_element_count = element_count * repetition_count;
    const ns_per_element = @as(f64, @floatFromInt(total_ns)) /
        @as(f64, @floatFromInt(total_element_count));
    try writer.print("{s: <24} {d:.2} ns/element\n", .{
        implementation_name(implementation),
        ns_per_element,
    });
}

fn implementation_name(implementation: Implementation) []const u8 {
    return switch (implementation) {
        .segmented_list => "SegmentedList",
        .array_list => "ArrayList",
        .memory_pool => "MemoryPool + ArrayList",
    };
}
