"""只生成合成 GPS JPEG、无 EXIF 缩略图与 HDR10 HEVC；不读取相册/用户媒体。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from PIL import Image, TiffImagePlugin


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=False)
    image = Image.new('RGB', (640, 360), (37, 104, 76))
    exif = Image.Exif()
    rat = TiffImagePlugin.IFDRational
    exif[0x8825] = {1: 'N', 2: (rat(12, 1), rat(34, 1), rat(56, 1)),
                    3: 'E', 4: (rat(65, 1), rat(43, 1), rat(21, 1))}
    exif[0x010E] = 'SYNTHETIC TEST ONLY - not user media/location'
    image.save(output / 'photo.bin', 'JPEG', quality=95, exif=exif)
    image.resize((160, 90)).save(output / 'thumb.bin', 'JPEG', quality=65)
    gps = Image.open(output / 'photo.bin').getexif().get_ifd(0x8825)
    assert gps[1] == 'N' and gps[3] == 'E'
    assert not Image.open(output / 'thumb.bin').getexif()
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                    '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=12:duration=1,noise=alls=80:allf=t+u',
                    '-pix_fmt', 'yuv420p10le', '-c:v', 'libx265', '-preset', 'ultrafast',
                    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc',
                    '-x265-params', 'lossless=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:repeat-headers=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:pools=1:frame-threads=1:log-level=error',
                    '-tag:v', 'hvc1', '-f', 'mp4', str(output / 'video.bin')], check=True, capture_output=True)
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                         '-show_streams', '-of', 'json', str(output / 'video.bin')]))
    stream = probe['streams'][0]
    assert stream['pix_fmt'] == 'yuv420p10le'
    assert stream['color_primaries'] == 'bt2020' and stream['color_transfer'] == 'smpte2084'
    assert stream['color_space'] == 'bt2020nc'
    frames = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                      '-read_intervals', '%+0.01', '-show_frames', '-of', 'json', str(output / 'video.bin')]))
    hdr = sorted({item['side_data_type'] for frame in frames.get('frames', [])
                  for item in frame.get('side_data_list', [])})
    assert 'Mastering display metadata' in hdr and 'Content light level metadata' in hdr
    manifest = {'version': 1, 'family_id': 'synthetic-family', 'backup_id': 'synthetic-media', 'entries': []}
    for ident, kind in [('photo', 'photo'), ('video', 'video'), ('thumb', 'thumbnail')]:
        file = output / (ident + '.bin')
        manifest['entries'].append({'id': ident, 'kind': kind, 'size': file.stat().st_size,
                                   'sha256': sha(file), 'source_exact': kind != 'thumbnail'})
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    evidence = {'fixture': 'wo-generated-synthetic-media-v1', 'contains_user_data': False,
                'sha_recorded_before_app_upload': True, 'gps_present': True,
                'thumbnail_has_exif': False, 'video_probe': probe, 'hdr_static_metadata': hdr,
                'sources': manifest['entries']}
    (output / 'source-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({'out': str(output), 'sources': manifest['entries']}))


if __name__ == '__main__':
    main()
