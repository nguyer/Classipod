enum DownloadQuality {
  original('Original / raw', null),
  high('High / 320 kbps MP3', 320),
  medium('Medium / 192 kbps MP3', 192),
  low('Low / 128 kbps MP3', 128);

  const DownloadQuality(this.label, this.bitrate);
  final String label;
  final int? bitrate;

  Map<String, String> get parameters => {
    'format': bitrate == null ? 'raw' : 'mp3',
    if (bitrate != null) 'maxBitRate': '$bitrate',
  };
}
