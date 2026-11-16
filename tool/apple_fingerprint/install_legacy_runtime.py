"""只在临时云端 Mac 安装 Apple 官方旧运行时，记录可用性与实际启动结果。"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

INDEX = 'https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    evidence = {'version': args.version, 'source': INDEX, 'booted': False, 'commands': []}
    mounted = False
    udid = None
    mount = root / 'mount'
    expanded = root / 'expanded'
    dmg = root / 'runtime.dmg'

    def command(argv, timeout=300, check=True):
        print('+', ' '.join(map(str, argv)), flush=True)
        number = len(evidence['commands'])
        stdout_path = root / f'command-{number}.stdout'
        stderr_path = root / f'command-{number}.stderr'
        with stdout_path.open('w') as stdout, stderr_path.open('w') as stderr:
            result = subprocess.run(list(map(str, argv)), stdout=stdout, stderr=stderr, timeout=timeout)
        # simctl 初次发现旧运行时会在 stderr 打印告警，不能混入 JSON 或设备 UUID。
        (root / f'command-{number}.log').write_text(stdout_path.read_text() + '\n--- stderr ---\n' + stderr_path.read_text())
        evidence['commands'].append({'argv': list(map(str, argv)), 'exit_code': result.returncode})
        if check and result.returncode:
            raise RuntimeError(f'命令失败，见 command-{number}.log')
        return stdout_path.read_text()

    try:
        raw = urllib.request.urlopen(INDEX, timeout=60).read()
        (root / 'apple-index.plist').write_bytes(raw)
        matches = [r for r in plistlib.loads(raw)['downloadables']
                   if r.get('platform') == 'com.apple.platform.iphoneos'
                   and r.get('simulatorVersion', {}).get('version') == args.version
                   and r.get('contentType') == 'package']
        if len(matches) != 1:
            raise RuntimeError('官方目录中没有唯一匹配的旧式 iOS 运行时')
        runtime = matches[0]
        evidence['runtime'] = runtime
        url = urllib.parse.urlparse(runtime['source'])
        if url.scheme != 'https' or url.hostname != 'devimages-cdn.apple.com':
            raise RuntimeError('下载地址不属于预期 Apple 官方 CDN')
        command(['sw_vers'])
        command(['xcodebuild', '-version'])
        command(['df', '-h', root])
        command(['curl', '--fail', '--location', '--retry', '2', '--max-time', '900',
                 '--output', dmg, runtime['source']], timeout=1000)
        # Apple 旧目录的 fileSize 与当前 CDN 文件可能不一致；保留差异，
        # 完整性由磁盘镜像校验和及安装包签名共同确认，不能仅凭目录大小中止。
        evidence['download_size'] = dmg.stat().st_size
        evidence['size_matches_catalog'] = dmg.stat().st_size == runtime['fileSize']
        digest = hashlib.sha256()
        with dmg.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        evidence['download_sha256'] = digest.hexdigest()
        command(['hdiutil', 'verify', dmg], timeout=300)
        mount.mkdir()
        command(['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mount, dmg])
        mounted = True
        packages = list(mount.glob('*.pkg'))
        if len(packages) != 1:
            raise RuntimeError('运行时镜像内安装包不唯一')
        command(['pkgutil', '--check-signature', packages[0]])
        command(['pkgutil', '--expand-full', packages[0], expanded], timeout=600)
        # 保留 Apple 原始二进制，只将旧包的运行时载荷放到标准发现目录。
        # 不改版本兼容条件；安装完成仍必须通过 simctl 的可用性和启动检查。
        bundles = []
        for info in expanded.glob('**/Contents/Info.plist'):
            data = plistlib.loads(info.read_bytes())
            if str(data.get('CFBundleIdentifier', '')).startswith('com.apple.CoreSimulator.SimRuntime.'):
                bundles.append(info.parent.parent)
                evidence['bundle_info'] = data
        if len(bundles) != 1:
            raise RuntimeError('不能唯一定位模拟器运行时载荷')
        destination = Path('/Library/Developer/CoreSimulator/Profiles/Runtimes') / f'iOS {args.version}.simruntime'
        if destination.exists():
            raise RuntimeError('目标已存在，停止以避免覆盖')
        command(['sudo', 'mkdir', '-p', destination.parent])
        command(['sudo', 'mv', bundles[0], destination], timeout=600)
        command(['plutil', '-lint', destination / 'Contents/Info.plist'])
        command(['hdiutil', 'detach', mount])
        mounted = False
        shutil.rmtree(expanded)
        dmg.unlink()
        # 目录监视器可能先看见移动过程；等待完成后重新查询一次，不缓存半安装状态。
        command(['xcrun', 'simctl', 'list', '--json'])
        time.sleep(5)
        data = json.loads(command(['xcrun', 'simctl', 'list', '--json']))
        (root / 'simulators.json').write_text(json.dumps(data, indent=2))
        found = [r for r in data['runtimes'] if r.get('version') == args.version and r.get('name', '').startswith('iOS ')]
        evidence['registered_runtimes'] = found
        if len(found) != 1 or not found[0].get('isAvailable'):
            raise RuntimeError('CoreSimulator 未将目标运行时标为可用')
        compatible = [d for d in found[0].get('supportedDeviceTypes', []) if d.get('productFamily') == 'iPhone']
        if not compatible:
            raise RuntimeError('运行时没有声明兼容的 iPhone 设备类型')
        udid = command(['xcrun', 'simctl', 'create', 'FluxDO-Legacy-Capability', compatible[0]['identifier'], found[0]['identifier']]).strip()
        command(['xcrun', 'simctl', 'boot', udid])
        command(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=240)
        evidence['booted'] = True
    except Exception as error:
        evidence['error'] = str(error)
        print(str(error), flush=True)
    finally:
        if udid:
            command(['xcrun', 'simctl', 'shutdown', udid], check=False)
            command(['xcrun', 'simctl', 'delete', udid], check=False)
        if mounted:
            command(['hdiutil', 'detach', mount], check=False)
        (root / 'capability.json').write_text(json.dumps(evidence, indent=2, default=str) + '\n')
    return 0 if evidence['booted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
