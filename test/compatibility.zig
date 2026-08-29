const std = @import("std");
const SegmentedList = @import("segmented_list").SegmentedList;
const testing = std.testing;

test "append" {
    var list: SegmentedList(u32, 0) = .empty;
    defer list.deinit(testing.allocator);

    for (0..32) |index| try list.append(testing.allocator, @intCast(index));
    try testing.expectEqual(@as(usize, 32), list.len);
    try testing.expectEqual(@as(u32, 17), list.at(17).*);

    var iterator = list.constIterator(0);
    var index: u32 = 0;
    while (iterator.next()) |item| : (index += 1) {
        try testing.expectEqual(index, item.*);
    }
    try testing.expectEqual(@as(u32, 32), index);
}

test "addOne" {
    var list: SegmentedList(u64, 8) = .empty;
    defer list.deinit(testing.allocator);

    for (0..32) |index| {
        const item = try list.addOne(testing.allocator);
        item.* = @intCast(index);
    }

    try testing.expectEqual(@as(usize, 32), list.len);
    for (0..list.len) |index| {
        try testing.expectEqual(@as(u64, @intCast(index)), list.at(index).*);
    }
}
