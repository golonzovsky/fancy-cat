// Types used in document handlers
pub const EncodedImage = struct {
    // PNG bytes, or — when is_path — the temp-file path holding them
    // (kitty graphics t=t medium: the terminal deletes the file after reading).
    data: []const u8,
    is_path: bool,
    width: u16,
    height: u16,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
};

pub const DocumentError = error{
    FailedToCreateContext,
    FailedToOpenDocument,
    FailedToRenderPage,
    InvalidPageNumber,
    UnsupportedFileFormat,
};
