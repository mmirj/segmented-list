# segmented-list

`SegmentedList` supports indexed access and bidirectional iteration without invalidating existing element pointers as it grows.

Elements are not guaranteed to be contiguous, so for that, use `std.ArrayList` instead.

## Use

Add the package:

```sh
zig fetch --save git+https://github.com/mmirj/segmented-list
```

In `build.zig`, add `b.dependency("segmented_list", .{}).module("segmented_list")` as the `segmented_list` import of each module that uses it.

## Example

```zig
const std = @import("std");
const SegmentedList = @import("segmented_list").SegmentedList;

test "stable element pointers" {
    var list: SegmentedList(u32, 4) = .empty;
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, 0);
    const first = list.at(0);

    for (1..5) |index| {
        try list.append(std.testing.allocator, @intCast(index));
    }

    try std.testing.expectEqual(@as(u32, 0), first.*);
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(list.at(0)));
}
```

The second type argument, `inline_capacity`, sets the maximum number of elements stored directly in the list and must be 0 or a power of two.
Use 0 when the list may be moved while an element pointer is in use.

## License

[MIT](LICENSE).
