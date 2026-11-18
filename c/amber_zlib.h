#include <zlib.h>

// amber_deflate compresses in with raw deflate (no zlib or gzip header, as ZIP
// needs) into out. It returns the compressed size, or -1 if it doesn't fit in
// out_cap bytes (so it isn't worth compressing) or fails.
static long long amber_deflate(const unsigned char *in, unsigned int in_len, unsigned char *out, unsigned int out_cap) {
	z_stream s = {0};
	if (deflateInit2(&s, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
		return -1;
	}
	s.next_in = (Bytef *)in;
	s.avail_in = in_len;
	s.next_out = out;
	s.avail_out = out_cap;
	int r = deflate(&s, Z_FINISH);
	long long n = r == Z_STREAM_END ? (long long)s.total_out : -1;
	deflateEnd(&s);
	return n;
}

// amber_inflate decompresses raw deflate data into out, which must be exactly
// the original size. It returns the decompressed size, or -1 on corrupt data.
static long long amber_inflate(const unsigned char *in, unsigned int in_len, unsigned char *out, unsigned int out_cap) {
	z_stream s = {0};
	if (inflateInit2(&s, -15) != Z_OK) {
		return -1;
	}
	s.next_in = (Bytef *)in;
	s.avail_in = in_len;
	s.next_out = out;
	s.avail_out = out_cap;
	int r = inflate(&s, Z_FINISH);
	long long n = r == Z_STREAM_END ? (long long)s.total_out : -1;
	inflateEnd(&s);
	return n;
}

static unsigned int amber_crc32(const unsigned char *data, unsigned int len) {
	return (unsigned int)crc32(0L, data, len);
}
