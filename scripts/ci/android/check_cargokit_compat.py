#!/usr/bin/env python3
"""离线执行已安装依赖的真实 Cargokit 任务，验证 Gradle 9 兼容转接。"""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
from urllib.parse import unquote, urlparse


def groovy(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle", required=True, help="Gradle 9 可执行文件")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    config_file = repo / ".dart_tool/package_config.json"
    config = json.loads(config_file.read_text())
    plugins = []
    for package in config["packages"]:
        uri = urlparse(package["rootUri"])
        root = Path(unquote(uri.path))
        if not uri.scheme:
            root = config_file.parent / root
        script = root / "cargokit/gradle/plugin.gradle"
        if script.is_file() and "project.exec" in script.read_text():
            plugins.append((package["name"], script.resolve()))
    if not plugins:
        raise SystemExit("未找到旧版 Cargokit；请先 flutter pub get，或确认是否可移除兼容层。")

    with tempfile.TemporaryDirectory(prefix="fluxdo cargokit ") as temporary:
        work = Path(temporary)
        names = [f"plugin{i}" for i in range(len(plugins))]
        (work / "settings.gradle").write_text(
            "rootProject.name = 'cargokit-compat-check'\n"
            + "\n".join(f"include {groovy(name)}" for name in [*names, "unrelated"])
        )
        root_build = work / "build.gradle"
        root_build.write_text("")
        for name, (package, source) in zip(names, plugins):
            child = work / name
            child.mkdir()
            runner = child / "fake kit/run_build_tool.sh"
            (runner.parent / "gradle").mkdir(parents=True)
            expected = {
                "CARGOKIT_ROOT_PROJECT_DIR": work,
                "CARGOKIT_TOOL_TEMP_DIR": child / "build/build_tool",
                "CARGOKIT_MANIFEST_DIR": child / "../rust",
                "CARGOKIT_CONFIGURATION": "release",
                "CARGOKIT_TARGET_TEMP_DIR": child / "build",
                "CARGOKIT_OUTPUT_DIR": child / "build/out",
                "CARGOKIT_NDK_VERSION": "test-ndk",
                "CARGOKIT_SDK_DIR": "test-sdk",
                "CARGOKIT_COMPILE_SDK_VERSION": "36",
                "CARGOKIT_MIN_SDK_VERSION": "23",
                "CARGOKIT_TARGET_PLATFORMS": "android-arm64,android-x64",
            }
            runner.write_text(
                '#!/bin/sh\nset -eu\ntest "$#" = 1\ntest "$1" = build-gradle\n'
                + "\n".join(
                    f'test "${key}" = {shlex.quote(str(value))}'
                    for key, value in expected.items()
                )
                + '\ntest -n "$CARGOKIT_JAVA_HOME"\n'
                + f"echo CARGOKIT_EXEC_OK:{package}\n"
                + 'exit "${FLUXDO_CARGOKIT_PROBE_EXIT:-0}"\n'
            )
            (child / "build.gradle").write_text(
                f"apply from: {groovy(source)}\n"
                "def plugin = plugins.find { it.class.name == 'CargoKitPlugin' }\n"
                "def taskClass = plugin.class.classLoader.loadClass('CargoKitBuildTask')\n"
                "cargokit { manifestDir = '../rust'; libname = 'probe' }\n"
                "tasks.register('probe', taskClass) {\n"
                " buildMode = 'release'; buildDir = layout.buildDirectory.get().asFile.toString()\n"
                " outputDir = buildDir + '/out'; ndkVersion = 'test-ndk'; sdkDirectory = 'test-sdk'\n"
                " compileSdkVersion = 36; minSdkVersion = 23\n"
                " pluginFile = project.file('fake kit/gradle/plugin.gradle').toString()\n"
                " targetPlatforms = ['android-arm64', 'android-x64']\n}\n"
            )
        unrelated = work / "unrelated"
        unrelated.mkdir()
        (unrelated / "build.gradle").write_text(
            "tasks.register('probe') { doLast { assert !project.ext.has('exec') } }\n"
        )
        command = [
            args.gradle, "-p", str(work), "--offline", "--no-daemon",
            "--max-workers=2", "-Dorg.gradle.jvmargs=-Xmx512m", "--console=plain",
        ]
        tasks = [f":{name}:probe" for name in [*names, "unrelated"]]

        def run(extra_env=None):
            return subprocess.run(
                [*command, *tasks, "--continue"], text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                env={**os.environ, **(extra_env or {})}, timeout=180,
            )

        baseline = run()
        if baseline.returncode == 0 or baseline.stdout.count("Could not find method exec()") < len(plugins):
            raise SystemExit("未复现每个旧版任务的原始错误：\n" + baseline.stdout)
        print(f"PASS: {len(plugins)} 个真实依赖复现 Project.exec 缺失", flush=True)

        compat = repo / "android/gradle/cargokit_compat.gradle"
        root_build.write_text(f"apply from: {groovy(compat)}\n")
        success = run()
        if success.returncode or any(
            f"CARGOKIT_EXEC_OK:{package}" not in success.stdout for package, _ in plugins
        ):
            raise SystemExit("兼容后执行失败：\n" + success.stdout)
        print("PASS: 命令、全部构建环境、含空格路径和其他插件隔离", flush=True)

        failure = run({"FLUXDO_CARGOKIT_PROBE_EXIT": "31"})
        if failure.returncode == 0 or failure.stdout.count("non-zero exit value 31") < len(plugins):
            raise SystemExit("子进程失败未正确传递：\n" + failure.stdout)
        print("PASS: 每个依赖的非零退出仍使构建失败", flush=True)


if __name__ == "__main__":
    main()
