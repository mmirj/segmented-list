const std = @import("std");
const SegmentedList = @import("segmented_list").SegmentedList;
const testing = std.testing;

const operation_count_max = 128;
const length_max = 128;

const InlineCapacity = enum(u2) { zero, one, four, sixteen };
const Operation = enum(u4) {
    append,
    append_slice,
    clear_and_free,
    clear_retaining_capacity,
    pop,
    reserve,
    resize,
    shrink_and_free,
    shrink_retaining_capacity,
};

test "fuzz operations against ArrayList" {
    try testing.fuzz({}, fuzz_operations, .{});
}

fn fuzz_operations(_: void, smith: *testing.Smith) !void {
    switch (smith.value(InlineCapacity)) {
        .zero => try fuzz_list(0, smith),
        .one => try fuzz_list(1, smith),
        .four => try fuzz_list(4, smith),
        .sixteen => try fuzz_list(16, smith),
    }
}

fn fuzz_list(comptime inline_capacity: usize, smith: *testing.Smith) !void {
    var list: SegmentedList(u32, inline_capacity) = .empty;
    defer list.deinit(testing.allocator);
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(testing.allocator);
    var addresses: std.ArrayList(usize) = .empty;
    defer addresses.deinit(testing.allocator);

    var next_item: u32 = 0;
    for (0..operation_count_max) |_| {
        if (smith.eosWeightedSimple(15, 1)) break;
        try apply_operation(&list, &expected, &addresses, smith, &next_item);
        try check_state(&list, &expected, &addresses);
    }
}

fn apply_operation(
    list: anytype,
    expected: *std.ArrayList(u32),
    addresses: *std.ArrayList(usize),
    smith: *testing.Smith,
    next_item: *u32,
) !void {
    switch (smith.value(Operation)) {
        .append => {
            if (list.len == length_max) return;
            const old_len = list.len;
            try list.append(testing.allocator, next_item.*);
            try expected.append(testing.allocator, next_item.*);
            next_item.* += 1;
            try record_addresses(list, addresses, old_len);
        },
        .append_slice => try append_slice(list, expected, addresses, smith, next_item),
        .clear_and_free => {
            list.clearAndFree(testing.allocator);
            expected.clearAndFree(testing.allocator);
            addresses.clearAndFree(testing.allocator);
        },
        .clear_retaining_capacity => {
            list.clearRetainingCapacity();
            expected.clearRetainingCapacity();
            addresses.clearRetainingCapacity();
        },
        .pop => {
            try testing.expectEqual(expected.pop(), list.pop());
            if (addresses.items.len != 0) {
                addresses.shrinkRetainingCapacity(addresses.items.len - 1);
            }
        },
        .reserve => {
            const additional_count = smith.value(u7);
            try list.ensureUnusedCapacity(testing.allocator, additional_count);
            try expected.ensureUnusedCapacity(testing.allocator, additional_count);
        },
        .resize => try resize(list, expected, addresses, smith, next_item),
        .shrink_and_free => {
            const new_len = smith.index(list.len + 1);
            list.shrinkAndFree(testing.allocator, new_len);
            expected.shrinkAndFree(testing.allocator, new_len);
            addresses.shrinkRetainingCapacity(new_len);
        },
        .shrink_retaining_capacity => {
            const new_len = smith.index(list.len + 1);
            list.shrinkRetainingCapacity(new_len);
            expected.shrinkRetainingCapacity(new_len);
            addresses.shrinkRetainingCapacity(new_len);
        },
    }
}

fn append_slice(
    list: anytype,
    expected: *std.ArrayList(u32),
    addresses: *std.ArrayList(usize),
    smith: *testing.Smith,
    next_item: *u32,
) !void {
    var buffer: [std.math.maxInt(u3)]u32 = undefined;
    const item_count = @min(smith.value(u3), length_max - list.len);
    const items = buffer[0..item_count];
    for (items) |*item| {
        item.* = next_item.*;
        next_item.* += 1;
    }

    const old_len = list.len;
    try list.appendSlice(testing.allocator, items);
    try expected.appendSlice(testing.allocator, items);
    try record_addresses(list, addresses, old_len);
}

fn resize(
    list: anytype,
    expected: *std.ArrayList(u32),
    addresses: *std.ArrayList(usize),
    smith: *testing.Smith,
    next_item: *u32,
) !void {
    const old_len = list.len;
    const new_len: usize = smith.valueRangeAtMost(u8, 0, length_max);
    try list.resize(testing.allocator, new_len);
    try expected.resize(testing.allocator, new_len);

    if (new_len < old_len) {
        addresses.shrinkRetainingCapacity(new_len);
    } else {
        for (old_len..new_len) |index| {
            list.at(index).* = next_item.*;
            expected.items[index] = next_item.*;
            next_item.* += 1;
        }
        try record_addresses(list, addresses, old_len);
    }
}

fn record_addresses(list: anytype, addresses: *std.ArrayList(usize), start_index: usize) !void {
    try addresses.ensureUnusedCapacity(testing.allocator, list.len - start_index);
    for (start_index..list.len) |index| {
        addresses.appendAssumeCapacity(@intFromPtr(list.at(index)));
    }
}

fn check_state(
    list: anytype,
    expected: *const std.ArrayList(u32),
    addresses: *const std.ArrayList(usize),
) !void {
    try testing.expectEqual(expected.items.len, list.len);
    try testing.expectEqual(addresses.items.len, list.len);
    try testing.expect(list.len <= list.capacity());
    for (expected.items, addresses.items, 0..) |item, address, index| {
        try testing.expectEqual(item, list.at(index).*);
        try testing.expectEqual(address, @intFromPtr(list.at(index)));
    }
}
