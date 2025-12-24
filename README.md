# Simple iOS RTSP Viewer

A lightweight RTSP viewer for iOS using SwiftUI, RTSP, RTP, and VideoToolbox (H.264).
No VLC. No ffmpeg.

## Features

- RTSP over TCP
- WiFi connection with IP Camera
- Digest authentication
- RTP H.264 (FU-A supported)
- VideoToolbox HW decoding
- Swift Concurrency (async/await)

## Connected Camera

- Jennov IP66

## Screenshot

| Simulator | iPhone |
|-----------|---------|
| ![](screenshots/emu0.png) | ![](screenshots/dev0.jpg) |


## Jennov IP66 packets
Client -> Server
```
OPTIONS rtsp://192.168.0.120:554/live/ch1 RTSP/1.0
CSeq: 2
User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
```

Server -> Client
```
RTSP/1.0 200 OK
CSeq: 2
Date: Fri, Dec 12 2025 00:55:52 GMT
Server: RTSP Server
Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER
```

Client -> Server
```
DESCRIBE rtsp://192.168.0.120:554/live/ch1 RTSP/1.0
CSeq: 3
User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
Accept: application/sdp
```

Server -> Client
```
RTSP/1.0 401 Unauthorized
Server: RTSP Server
CSeq: 3
WWW-Authenticate: Digest realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b"
```

Client -> Server
```
Authorization: Digest username="TuPF7d6h", realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b", uri="rtsp://192.168.0.120:554/live/ch1", response="d64b48e2fba3302a1a7e1f4ad7997cb1"
CSeq: 4
User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
Accept: application/sdp
```

Server -> Client
```
RTSP/1.0 200 OK
CSeq: 4
Date: Fri, Dec 12 2025 00:55:52 GMT
Server: RTSP Server
Content-type: application/sdp
Content-length: 631
(SDP body)
v=0
o=- 1765500952 1765500953 IN IP4 192.168.0.120
s=streamed by RTSP server
e=NONE
b=AS:1088
t=0 0
m=video 0 RTP/AVP 96
c=IN IP4 0.0.0.0
b=AS:1024
a=recvonly
a=x-dimensions:640,360
a=rtpmap:96 H264/90000
a=control:track0
a=fmtp:96 packetization-mode=1;profile-level-id=640016;sprop-parameter-sets=Z2QAFqw7UFAX/LCAAAADAIAAAA9C,aO484QBCQgCEhARMUhuTxXyfk/k/J8nm5MkkLCJCkJyeT6/J/X5PrycmpMA=
m=audio 0 RTP/AVP 97
c=IN IP4 0.0.0.0
b=AS:64
a=recvonly
a=control:track1
a=rtpmap:97 MPEG4-GENERIC/8000/1
a=fmtp:97 profile-level-id=15;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1588;profile=1;
```

Client -> Server
```
SETUP rtsp://192.168.0.120:554/live/ch1/track0 RTSP/1.0
CSeq: 5
Authorization: Digest username="TuPF7d6h", realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b", uri="rtsp://192.168.0.120:554/live/ch1", response="3dc93376d770e74d7a6344a3c9bf76c1"
User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
Transport: RTP/AVP;unicast;client_port=51748-51749
```

Server -> Client
```
RTSP/1.0 200 OK
CSeq: 5
Date: Fri, Dec 12 2025 00:55:52 GMT
Server: RTSP Server
Session: 6959096903166427680; timeout=60;
Transport: RTP/AVP/UDP;unicast;client_port=51748-51749;server_port=51628-51629;timeout=60
```

Client -> Server
```
SETUP rtsp://192.168.0.120:554/live/ch1/track1 RTSP/1.0
CSeq: 6
Authorization: Digest username="TuPF7d6h", realm="HHRtspd", nonce="6d99d427676c352fd9d15635e5da608b", uri="rtsp://192.168.0.120:554/live/ch1", response="3dc93376d770e74d7a6344a3c9bf76c1"
User-Agent: LibVLC/3.0.18 (LIVE555 Streaming Media v2016.11.28)
Transport: RTP/AVP;unicast;client_port=55650-55651
Session: 6959096903166427680
```

Server -> Client
```
RTSP/1.0 200 OK
CSeq: 6
Date: Fri, Dec 12 2025 00:55:52 GMT
Server: RTSP Server
Session: 6959096903166427680; timeout=60;
Transport: RTP/AVP/UDP;unicast;client_port=55650-55651;server_port=50362-50363;timeout=60
```