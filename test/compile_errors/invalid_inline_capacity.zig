const SegmentedList = @import("segmented_list").SegmentedList;

comptime {
    _ = SegmentedList(u8, 3);
}
