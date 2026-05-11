// Types used in document handlers
pub const EncodedImage = struct {
    base64: []const u8,
    width: u16,
    height: u16,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
};

pub const ScrollDirection = enum { Up, Down, Left, Right };

pub const DocumentError = error{
    FailedToCreateContext,
    FailedToOpenDocument,
    FailedToRenderPage,
    InvalidPageNumber,
    UnsupportedFileFormat,
};
