const std = @import("std");
const SegmentedList = @import("segmented_list").SegmentedList;
const testing = std.testing;

test "capacity and indexing" {
    inline for (.{ 0, 1, 2, 4, 8, 16 }) |inline_capacity| {
        try check_geometry(inline_capacity);
    }
}

fn check_geometry(comptime inline_capacity: usize) !void {
    var list: SegmentedList(u16, inline_capacity) = .empty;
    defer list.deinit(testing.allocator);

    try testing.expectEqual(inline_capacity, list.capacity());
    var previous_capacity = list.capacity();
    for (0..129) |index| {
        try list.append(testing.allocator, @intCast(index));
        const expected_capacity = capacity_for_minimum(inline_capacity, list.len);
        try testing.expectEqual(expected_capacity, list.capacity());
        if (list.capacity() != previous_capacity) {
            try testing.expect(list.capacity() < (2 * list.len));
            previous_capacity = list.capacity();
        }
        for (0..list.len) |item_index| {
            try testing.expectEqual(@as(u16, @intCast(item_index)), list.at(item_index).*);
        }
    }
}

fn capacity_for_minimum(comptime inline_capacity: usize, minimum: usize) usize {
    var element_capacity: usize = inline_capacity;
    var next_segment_size: usize = if (inline_capacity == 0) 1 else inline_capacity;
    while (element_capacity < minimum) {
        element_capacity += next_segment_size;
        next_segment_size *= 2;
    }
    return element_capacity;
}

test "basic usage" {
    const List = SegmentedList(u32, 4);
    var list: List = .empty;
    defer list.deinit(testing.allocator);

    try list.ensureTotalCapacity(testing.allocator, 19);
    try testing.expectEqual(@as(usize, 32), list.capacity());
    list.appendAssumeCapacity(0);
    list.appendSliceAssumeCapacity(&.{ 1, 2, 3, 4, 5, 6, 7 });

    const added = list.addOneAssumeCapacity();
    added.* = 8;
    try list.resize(testing.allocator, 12);
    for (9..12) |index| list.at(index).* = @intCast(index);

    var copied: [8]u32 = undefined;
    list.copyToSlice(&copied, 2);
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7, 8, 9 }, &copied);
    try testing.expectEqual(@as(u32, 11), list.pop().?);

    list.shrinkRetainingCapacity(5);
    const retained_capacity = list.capacity();
    list.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expectEqual(retained_capacity, list.capacity());

    try list.append(testing.allocator, 0);
    list.clearAndFree(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expectEqual(List.inline_capacity, list.capacity());
}

test "appendSlice across segments" {
    var list: SegmentedList(u32, 4) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, &.{ 0, 1, 2, 3, 4, 5 });
    try list.appendSlice(testing.allocator, &.{ 6, 7, 8, 9 });
    try testing.expectEqual(@as(usize, 10), list.len);
    for (0..list.len) |index| {
        try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).*);
    }
}

test "clearAndFree with inline capacity 0" {
    var list: SegmentedList(u32, 0) = .empty;
    defer list.deinit(testing.allocator);

    for (0..32) |index| try list.append(testing.allocator, @intCast(index));
    list.clearAndFree(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expectEqual(@as(usize, 0), list.capacity());

    try list.append(testing.allocator, 0);
    try testing.expectEqual(@as(u32, 0), list.at(0).*);
}

test "iterators" {
    try check_iterator_boundaries(0, 15);
    try check_iterator_boundaries(2, 16);

    var list: SegmentedList(u32, 2) = .empty;
    defer list.deinit(testing.allocator);
    for (0..10) |index| try list.append(testing.allocator, @intCast(index));

    var iterator = list.iterator(3);
    try testing.expectEqual(@as(u32, 3), iterator.next().?.*);
    try testing.expectEqual(@as(u32, 3), iterator.prev().?.*);
    try testing.expectEqual(@as(u32, 2), iterator.prev().?.*);

    var mutable_iterator = list.iterator(0);
    while (mutable_iterator.next()) |item| item.* += 1;
    try testing.expectEqual(@as(?*u32, null), mutable_iterator.next());

    const const_list: *const @TypeOf(list) = &list;
    const const_item = const_list.at(0);
    comptime std.debug.assert(@TypeOf(const_item) == *const u32);
    var const_iterator = const_list.constIterator(const_list.len);
    var expected_value: u32 = 10;
    while (const_iterator.prev()) |item| {
        comptime std.debug.assert(@TypeOf(item) == *const u32);
        try testing.expectEqual(expected_value, item.*);
        expected_value -= 1;
    }
    try testing.expectEqual(@as(u32, 0), expected_value);
    try testing.expectEqual(@as(?*const u32, null), const_iterator.prev());
}

fn check_iterator_boundaries(comptime inline_capacity: usize, length: usize) !void {
    var list: SegmentedList(u32, inline_capacity) = .empty;
    defer list.deinit(testing.allocator);
    for (0..length) |index| try list.append(testing.allocator, @intCast(index));
    try testing.expectEqual(length, list.capacity());

    for (0..length + 1) |start_index| {
        var iterator = list.constIterator(start_index);
        if (start_index == 0) try testing.expectEqual(@as(?*const u32, null), iterator.prev());
        if (start_index == length) {
            try testing.expectEqual(@as(?*const u32, null), iterator.next());
        }
        if (start_index < length) {
            try testing.expectEqual(@as(u32, @intCast(start_index)), iterator.next().?.*);
            try testing.expectEqual(@as(u32, @intCast(start_index)), iterator.prev().?.*);
        }
        if (start_index > 0) {
            const previous_index = start_index - 1;
            try testing.expectEqual(@as(u32, @intCast(previous_index)), iterator.prev().?.*);
            try testing.expectEqual(@as(u32, @intCast(previous_index)), iterator.next().?.*);
        }
    }
}

test "stable element pointers" {
    inline for (.{ 0, 4 }) |inline_capacity| {
        try check_pointer_stability(inline_capacity);
    }
}

fn check_pointer_stability(comptime inline_capacity: usize) !void {
    var list: SegmentedList(u64, inline_capacity) = .empty;
    defer list.deinit(testing.allocator);
    var pointers: [64]*u64 = undefined;

    for (0..pointers.len) |index| {
        try list.append(testing.allocator, @intCast(index));
        pointers[index] = list.at(index);
        for (0..list.len) |retained_index| {
            const original_address = @intFromPtr(pointers[retained_index]);
            const current_address = @intFromPtr(list.at(retained_index));
            try testing.expectEqual(original_address, current_address);
            try testing.expectEqual(@as(u64, @intCast(retained_index)), pointers[retained_index].*);
        }
    }

    list.shrinkAndFree(testing.allocator, 17);
    try testing.expectEqual(capacity_for_minimum(inline_capacity, 17), list.capacity());
    for (0..list.len) |index| {
        try testing.expectEqual(@intFromPtr(pointers[index]), @intFromPtr(list.at(index)));
    }

    list.shrinkAndFree(testing.allocator, inline_capacity);
    try testing.expectEqual(inline_capacity, list.len);
    try testing.expectEqual(inline_capacity, list.capacity());
    for (0..list.len) |index| {
        try testing.expectEqual(@intFromPtr(pointers[index]), @intFromPtr(list.at(index)));
        try testing.expectEqual(@as(u64, @intCast(index)), list.at(index).*);
    }

    try list.append(testing.allocator, @intCast(pointers.len));
    try testing.expectEqual(inline_capacity + 1, list.len);
    try testing.expectEqual(@as(u64, pointers.len), list.at(inline_capacity).*);
}

test "zero-sized and over-aligned elements" {
    try check_zero_sized_elements(0);
    try check_zero_sized_elements(8);
    try check_over_aligned_elements();
}

fn check_zero_sized_elements(comptime inline_capacity: usize) !void {
    const Empty = struct {};
    var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_state.allocator();
    var list: SegmentedList(Empty, inline_capacity) = .empty;
    defer list.deinit(allocator);

    const items = [_]Empty{ .{}, .{}, .{} };
    try list.appendSlice(allocator, &items);
    list.appendSliceAssumeCapacity(&items);
    try testing.expectEqual(@as(usize, 6), list.len);

    var iterator = list.constIterator(list.len);
    var iterated_count: usize = 0;
    while (iterator.prev()) |_| iterated_count += 1;
    try testing.expectEqual(list.len, iterated_count);

    try list.resize(allocator, std.math.maxInt(usize));
    try testing.expectEqual(std.math.maxInt(usize), list.capacity());
    _ = list.at(std.math.maxInt(usize) - 1);
    try testing.expectError(error.OutOfMemory, list.addOne(allocator));
    try testing.expect(!failing_state.has_induced_failure);
}

test "ensureUnusedCapacity overflow" {
    var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_state.allocator();
    var list: SegmentedList(u32, 1) = .empty;
    defer list.deinit(allocator);
    list.appendAssumeCapacity(0);

    try testing.expectError(
        error.OutOfMemory,
        list.ensureUnusedCapacity(allocator, std.math.maxInt(usize)),
    );
    try testing.expect(!failing_state.has_induced_failure);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(usize, 1), list.capacity());
    try testing.expectEqual(@as(u32, 0), list.at(0).*);
}

test "ensureTotalCapacity allocation failure" {
    var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_state.allocator();
    var list: SegmentedList(u32, 4) = .empty;
    defer list.deinit(allocator);
    list.appendSliceAssumeCapacity(&.{ 0, 1, 2, 3 });

    try testing.expectError(
        error.OutOfMemory,
        list.ensureTotalCapacity(allocator, std.math.maxInt(usize)),
    );
    try testing.expect(failing_state.has_induced_failure);
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqual(@as(usize, 4), list.capacity());
    for (0..4) |index| {
        try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).*);
    }
}

fn check_over_aligned_elements() !void {
    const OverAligned = struct { lanes: @Vector(16, u32) };
    var list: SegmentedList(OverAligned, 1) = .empty;
    defer list.deinit(testing.allocator);

    for (0..33) |index| {
        const lanes: @Vector(16, u32) = @splat(@as(u32, @intCast(index)));
        try list.append(testing.allocator, .{ .lanes = lanes });
        try testing.expectEqual(@as(usize, 0), @intFromPtr(list.at(index)) % @alignOf(OverAligned));
        try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).lanes[0]);
    }
}

test "operations match ArrayList" {
    inline for (.{ 0, 1, 4, 16 }) |inline_capacity| {
        try check_model(inline_capacity);
    }
}

const ModelOperation = enum { append, append_slice, clear, pop, reserve, resize, shrink };

fn check_model(comptime inline_capacity: usize) !void {
    var segmented_list: SegmentedList(u32, inline_capacity) = .empty;
    defer segmented_list.deinit(testing.allocator);
    var array_list: std.ArrayList(u32) = .empty;
    defer array_list.deinit(testing.allocator);

    var generator = std.Random.DefaultPrng.init(inline_capacity);
    const random = generator.random();
    for (0..2000) |step| {
        try apply_model_operation(&segmented_list, &array_list, random, step);
        try testing.expectEqual(array_list.items.len, segmented_list.len);
        for (array_list.items, 0..) |item, index| {
            try testing.expectEqual(item, segmented_list.at(index).*);
        }
    }
}

fn apply_model_operation(
    segmented_list: anytype,
    array_list: anytype,
    random: std.Random,
    step: usize,
) !void {
    switch (random.enumValue(ModelOperation)) {
        .append => {
            const item: u32 = @intCast(step);
            try segmented_list.append(testing.allocator, item);
            try array_list.append(testing.allocator, item);
        },
        .append_slice => {
            const item: u32 = @intCast(step);
            const items = [2]u32{ item, item + 1 };
            try segmented_list.appendSlice(testing.allocator, &items);
            try array_list.appendSlice(testing.allocator, &items);
        },
        .clear => {
            segmented_list.clearRetainingCapacity();
            array_list.clearRetainingCapacity();
        },
        .pop => try testing.expectEqual(array_list.pop(), segmented_list.pop()),
        .reserve => {
            const additional_count = random.uintLessThan(usize, 65);
            try segmented_list.ensureUnusedCapacity(testing.allocator, additional_count);
            try array_list.ensureUnusedCapacity(testing.allocator, additional_count);
        },
        .resize => try resize_model(segmented_list, array_list, random, step),
        .shrink => {
            const new_len = random.uintAtMost(usize, segmented_list.len);
            segmented_list.shrinkRetainingCapacity(new_len);
            array_list.shrinkRetainingCapacity(new_len);
        },
    }
}

fn resize_model(
    segmented_list: anytype,
    array_list: anytype,
    random: std.Random,
    step: usize,
) !void {
    const old_len = segmented_list.len;
    const new_len = random.uintLessThan(usize, 65);
    try segmented_list.resize(testing.allocator, new_len);
    try array_list.resize(testing.allocator, new_len);

    if (new_len > old_len) {
        for (old_len..new_len) |index| {
            const item: u32 = @intCast((step * 65) + index);
            segmented_list.at(index).* = item;
            array_list.items[index] = item;
        }
    }
}

test "appendSlice allocation failure" {
    var observed_success = false;
    for (0..16) |failure_index| {
        if (try append_slice_failure_case(failure_index)) {
            observed_success = true;
            break;
        }
    }
    try testing.expect(observed_success);
}

fn append_slice_failure_case(failure_index: usize) !bool {
    var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = failure_index,
    });
    const allocator = failing_state.allocator();
    var list: SegmentedList(u32, 4) = .empty;
    defer list.deinit(allocator);
    list.appendSliceAssumeCapacity(&.{ 0, 1, 2, 3 });

    var items: [60]u32 = undefined;
    for (&items, 4..) |*item, value| item.* = @intCast(value);
    const inline_addresses = [_]usize{
        @intFromPtr(list.at(0)),
        @intFromPtr(list.at(1)),
        @intFromPtr(list.at(2)),
        @intFromPtr(list.at(3)),
    };

    list.appendSlice(allocator, &items) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(failing_state.has_induced_failure);
        try expect_inline_storage_unchanged(&list, &inline_addresses);
        try testing.expectEqual(failing_state.allocated_bytes, failing_state.freed_bytes);
        return false;
    };

    try testing.expectEqual(@as(usize, 64), list.len);
    for (0..list.len) |index| try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).*);
    return true;
}

fn expect_inline_storage_unchanged(list: anytype, addresses: *const [4]usize) !void {
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqual(@as(usize, 4), list.capacity());
    for (0..4) |index| {
        try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).*);
        try testing.expectEqual(addresses[index], @intFromPtr(list.at(index)));
    }
}

test "ensureTotalCapacity allocation failure with existing segments" {
    var observed_success = false;
    for (0..16) |failure_index| {
        if (try existing_storage_failure_case(failure_index)) {
            observed_success = true;
            break;
        }
    }
    try testing.expect(observed_success);
}

fn existing_storage_failure_case(failure_index: usize) !bool {
    var list: SegmentedList(u32, 0) = .empty;
    errdefer list.deinit(testing.allocator);
    for (0..8) |index| try list.append(testing.allocator, @intCast(index));
    const old_capacity = list.capacity();
    var addresses: [8]usize = undefined;
    for (&addresses, 0..) |*address, index| address.* = @intFromPtr(list.at(index));

    var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = failure_index,
    });
    const allocator = failing_state.allocator();
    list.ensureTotalCapacity(allocator, 127) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(failing_state.has_induced_failure);
        try expect_existing_storage(&list, old_capacity, &addresses);
        try testing.expectEqual(failing_state.allocated_bytes, failing_state.freed_bytes);
        list.deinit(testing.allocator);
        return false;
    };

    list.deinit(allocator);
    return true;
}

fn expect_existing_storage(list: anytype, capacity: usize, addresses: *const [8]usize) !void {
    try testing.expectEqual(@as(usize, 8), list.len);
    try testing.expectEqual(capacity, list.capacity());
    for (0..8) |index| {
        try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).*);
        try testing.expectEqual(addresses[index], @intFromPtr(list.at(index)));
    }
}

test "ensureTotalCapacity allocation failure after shrinkAndFree" {
    var observed_success = false;
    for (0..8) |relative_failure_index| {
        if (try retained_directory_failure_case(relative_failure_index)) {
            observed_success = true;
            break;
        }
    }
    try testing.expect(observed_success);
}

fn retained_directory_failure_case(relative_failure_index: usize) !bool {
    var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{
        .resize_fail_index = 0,
    });
    const allocator = failing_state.allocator();
    var list: SegmentedList(u32, 0) = .empty;
    defer list.deinit(allocator);
    for (0..31) |index| try list.append(allocator, @intCast(index));
    list.shrinkAndFree(allocator, 3);

    const allocated_before = failing_state.allocated_bytes;
    const freed_before = failing_state.freed_bytes;
    failing_state.fail_index = failing_state.alloc_index + relative_failure_index;
    list.ensureTotalCapacity(allocator, 15) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(failing_state.has_induced_failure);
        try testing.expectEqual(@as(usize, 3), list.capacity());
        const allocated_during_growth = failing_state.allocated_bytes - allocated_before;
        const freed_during_growth = failing_state.freed_bytes - freed_before;
        try testing.expectEqual(allocated_during_growth, freed_during_growth);
        for (0..3) |index| try testing.expectEqual(@as(u32, @intCast(index)), list.at(index).*);
        return false;
    };
    try testing.expectEqual(@as(usize, 15), list.capacity());
    return true;
}
