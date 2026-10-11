import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid
import zlib


PROJECT = Path(__file__).resolve().parents[1]
CLI = PROJECT / "build" / "app-clone"


def png(path, color, width=192, height=96):
    def chunk(kind, payload):
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", checksum)
        )

    row = b"\0" + bytes(color) * width
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * height))
        + chunk(b"IEND", b"")
    )


def digest_tree(path):
    return {
        str(item.relative_to(path)): hashlib.sha256(item.read_bytes()).hexdigest()
        for item in path.rglob("*")
        if item.is_file() and not item.is_symlink()
    }


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(
            prefix="app-clone-build-", dir="/private/tmp"
        )
        cls.program = Path(cls.shared.name) / "fixture"
        subprocess.run(
            ["/usr/bin/clang", "-x", "c", "-", "-o", str(cls.program)],
            input=b"int main(void) { return 0; }\n",
            check=True,
            capture_output=True,
        )
        cls.environment_program = Path(cls.shared.name) / "environment-fixture"
        environment_source = Path(cls.shared.name) / "environment-fixture.m"
        environment_source.write_bytes(
            b"""#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    const char *keys[] = {"HOME", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "LANG", "LC_ALL", "APP_CLONE_ORIGINAL_HOME"};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        const char *value = getenv(keys[i]);
        printf("%s=%s\\n", keys[i], value ? value : "<unset>");
    }
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        printf("APPLE_LANGUAGE=%s\\n", [[NSLocale preferredLanguages].firstObject UTF8String]);
        printf("GREETING=%s\\n", [NSLocalizedString(@"greeting", nil) UTF8String]);
        printf("ARGUMENT=%s\\n", [[defaults stringForKey:@"FixtureArgument"] UTF8String]);
        id saved = [defaults persistentDomainForName:[NSBundle mainBundle].bundleIdentifier][@"AppleLanguages"];
        printf("SAVED_LANGUAGE=%s\\n", saved ? "present" : "<unset>");
    }
    return 0;
}
"""
        )
        subprocess.run(
            [
                "/usr/bin/clang",
                "-arch",
                "arm64",
                "-arch",
                "x86_64",
                "-Wl,-headerpad,0x400",
                "-x",
                "objective-c",
                "-fobjc-arc",
                "-framework",
                "Foundation",
                str(environment_source),
                "-o",
                str(cls.environment_program),
            ],
            check=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="app-clone-test-", dir="/private/tmp"
        )
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.root = self.directory / "workspace"
        self.source = self.directory / "origin.app"
        contents = self.source / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        resources = contents / "Resources"
        (resources / "zh.lproj").mkdir(parents=True)
        shutil.copy2(self.program, contents / "MacOS" / "fixture")
        self.plist = contents / "Info.plist"
        self.info = {
            "CFBundleIdentifier": "local.app-clone.fixture",
            "CFBundleExecutable": "fixture",
            "CFBundleName": "原应用",
            "CFBundleDisplayName": "原应用",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleIconName": "old-asset",
        }
        self.plist.write_bytes(plistlib.dumps(self.info))
        (resources / "zh.lproj" / "InfoPlist.strings").write_bytes(
            plistlib.dumps(
                {"CFBundleDisplayName": "旧名字", "CFBundleIconName": "old-asset"}
            )
        )
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(self.source)],
            check=True,
            capture_output=True,
        )
        self.red = self.directory / "red.png"
        self.blue = self.directory / "blue.png"
        png(self.red, (220, 60, 60, 255))
        png(self.blue, (60, 90, 230, 255))
        self.original = digest_tree(self.source)

    def cli(self, *arguments, success=True, workspace=True):
        workspace_args = ["--workspace", str(self.root)] if workspace else []
        result = subprocess.run(
            [str(CLI), *map(str, arguments), *workspace_args, "--json"],
            capture_output=True,
            text=True,
            timeout=45,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stderr)

    def create(self, icon=True, name="微信工作测试"):
        args = ["clone", self.source, "--name", name]
        if icon:
            args += ["--icon", self.red]
        return self.cli(*args)

    def app(self, record):
        return self.root / "apps" / record.get("appFileName", record["id"] + ".app")

    def make_legacy(self, record):
        old_path = self.root / "apps" / (record["id"] + ".app")
        self.app(record).rename(old_path)
        catalog_path = self.root / "state.json"
        catalog = json.loads(catalog_path.read_text())
        catalog["schemaVersion"] = 1
        catalog.pop("creationCounts", None)
        catalog.pop("historyComplete", None)
        for item in catalog["clones"]:
            if item["id"] == record["id"]:
                del item["appFileName"]
                item.pop("cloneNumber", None)
        catalog_path.write_text(json.dumps(catalog))
        return {
            key: value
            for key, value in record.items()
            if key not in ("appFileName", "cloneNumber")
        }

    def icon_path(self, record):
        return self.app(record) / "Contents" / "Resources" / "app-clone.icns"

    def assert_clean(self):
        self.assertFalse((self.root / "pending.json").exists())
        self.assertEqual(list((self.root / "staging").iterdir()), [])

    def use_environment_fixture(self):
        shutil.copy2(self.environment_program, self.source / "Contents/MacOS/fixture")
        self.info["CFBundleDevelopmentRegion"] = "en"
        self.plist.write_bytes(plistlib.dumps(self.info))
        for language, greeting in [
            ("en", "Hello"),
            ("zh-Hans", "Chinese"),
            ("ja", "Japanese"),
        ]:
            resources = self.source / "Contents/Resources" / f"{language}.lproj"
            resources.mkdir(exist_ok=True)
            (resources / "Localizable.strings").write_text(
                f'"greeting" = "{greeting}";\n'
            )
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(self.source)],
            check=True,
            capture_output=True,
        )
        self.original = digest_tree(self.source)

    def run_environment_fixture(self, app, *arguments):
        result = subprocess.run(
            [
                str(app / "Contents/MacOS/fixture"),
                "-FixtureArgument",
                "keep",
                *arguments,
            ],
            env={
                "HOME": "/example/inherited-home",
                "TMPDIR": "/example/inherited-tmp/",
                "LANG": "C",
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def test_adv_clone_help_and_read_only_status(self):
        for language, phrase in [("zh", "用法："), ("en", "Usage:")]:
            for suffix in [[], ["--help"]]:
                result = self.localized_cli("adv-clone", *suffix, "--lang", language)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(phrase, result.stdout)
                self.assertIn("--reset", result.stdout)
                self.assertIn("--app-language", result.stdout)
        record = self.create(icon=False)
        before = digest_tree(self.root)
        self.assertEqual(
            self.cli("adv-clone", self.app(record), workspace=False), record
        )
        self.assertEqual(digest_tree(self.root), before)
        self.assertEqual(
            self.cli("adv-clone", self.source, success=False)["code"], "not_managed"
        )

    def test_adv_clone_environment_applies_updates_and_resets(self):
        self.use_environment_fixture()
        record = self.create(icon=False)
        stats = self.cli("stats")
        app = self.app(record)
        baseline = self.run_environment_fixture(app)
        data = self.directory / '数据 "quoted" \\ dir'
        configured = self.cli(
            "adv-clone",
            app,
            "--data-dir",
            data,
            "--proxy",
            "http://127.0.0.1:7890",
            "--locale",
            "zh_CN.UTF-8",
            workspace=False,
        )
        self.assertEqual(configured["id"], record["id"])
        self.assertEqual(configured["environment"]["dataDirectory"], str(data))
        self.assertNotIn("appLanguage", configured["environment"])
        self.assertEqual(len(configured["environment"]["dylibSHA256"]), 64)
        self.assertTrue((data / "home").is_dir())
        self.assertEqual((data / "tmp").stat().st_mode & 0o777, 0o700)
        values = self.run_environment_fixture(app)
        self.assertEqual(values["HOME"], str(data / "home"))
        self.assertEqual(values["TMPDIR"], str(data / "tmp") + "/")
        self.assertEqual(values["HTTP_PROXY"], "http://127.0.0.1:7890")
        self.assertEqual(values["HTTPS_PROXY"], values["HTTP_PROXY"])
        self.assertEqual(values["LANG"], "zh_CN.UTF-8")
        self.assertEqual(values["LC_ALL"], values["LANG"])
        self.assertEqual(values["APP_CLONE_ORIGINAL_HOME"], baseline["HOME"])
        self.cli("verify", app)
        updated = self.cli("adv-clone", app, "--proxy", "https://localhost:8888")
        self.assertEqual(updated["environment"]["dataDirectory"], str(data))
        self.assertEqual(updated["environment"]["locale"], "zh_CN.UTF-8")
        dependencies = subprocess.run(
            [
                "/usr/bin/otool",
                "-arch",
                "all",
                "-L",
                str(app / "Contents/MacOS/fixture"),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertEqual(
            dependencies.count("@executable_path/../Frameworks/libappclone_env.dylib"),
            2,
        )
        self.assertEqual(
            self.run_environment_fixture(app)["HTTP_PROXY"], "https://localhost:8888"
        )
        saved = data / "home" / "user-data.txt"
        saved.write_text("preserve me")
        reset = self.cli("adv-clone", app, "--reset")
        self.assertNotIn("environment", reset)
        self.assertFalse((app / "Contents/Frameworks/libappclone_env.dylib").exists())
        self.assertEqual(self.run_environment_fixture(app), baseline)
        self.assertEqual(saved.read_text(), "preserve me")
        self.assertEqual(self.cli("stats"), stats)
        self.assertEqual(digest_tree(self.source), self.original)
        self.cli("verify", app)
        self.assert_clean()

    def test_adv_clone_app_languages_are_isolated_and_reset(self):
        self.use_environment_fixture()
        chinese = self.app(self.create(icon=False, name="中文分身"))
        japanese = self.app(self.create(icon=False, name="日文分身"))
        baseline = self.run_environment_fixture(chinese)
        source_baseline = self.run_environment_fixture(self.source)
        for app, language, greeting in [
            (chinese, "zh-CN", "Chinese"),
            (japanese, "ja", "Japanese"),
        ]:
            configured = self.cli("adv-clone", app, "--app-language", language)
            self.assertEqual(configured["environment"]["appLanguage"], language)
            for _ in range(2):
                values = self.run_environment_fixture(app)
                self.assertEqual(values["GREETING"], greeting)
                self.assertEqual(values["APPLE_LANGUAGE"], language)
                self.assertEqual(values["LANG"], "C")
                self.assertEqual(values["LC_ALL"], "<unset>")
                self.assertEqual(values["ARGUMENT"], "keep")
                self.assertEqual(values["SAVED_LANGUAGE"], "<unset>")
            self.cli("verify", app)
        self.assertEqual(self.run_environment_fixture(chinese)["GREETING"], "Chinese")
        self.assertEqual(self.run_environment_fixture(self.source), source_baseline)
        overridden = self.run_environment_fixture(chinese, "-AppleLanguages", "(en)")
        self.assertEqual(overridden["GREETING"], "Hello")
        self.assertEqual(overridden["APPLE_LANGUAGE"], "en")
        self.assertEqual(self.run_environment_fixture(chinese)["GREETING"], "Chinese")
        updated = self.cli("adv-clone", chinese, "--locale", "en_US.UTF-8")
        self.assertEqual(updated["environment"]["appLanguage"], "zh-CN")
        self.assertEqual(self.run_environment_fixture(chinese)["GREETING"], "Chinese")
        self.cli("adv-clone", chinese, "--app-language", "en")
        values = self.run_environment_fixture(chinese)
        self.assertEqual(values["GREETING"], "Hello")
        self.assertEqual(values["LANG"], "en_US.UTF-8")
        status = self.localized_cli("adv-clone", chinese, "--lang", "zh")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn("应用界面语言：en", status.stdout)
        self.cli("adv-clone", chinese, "--reset")
        self.assertEqual(self.run_environment_fixture(chinese), baseline)
        self.assertEqual(self.run_environment_fixture(japanese)["GREETING"], "Japanese")
        self.assertEqual(digest_tree(self.source), self.original)
        self.assert_clean()

    def test_adv_clone_survives_rename_icon_and_removal(self):
        self.use_environment_fixture()
        record = self.create(icon=False)
        data = self.root / "data" / record["id"]
        configured = self.cli("adv-clone", self.app(record), "--data-dir", data)
        renamed = self.cli("rename", self.app(configured), "新名字")
        changed = self.cli("icon", self.app(renamed), self.red)
        self.assertEqual(changed["environment"]["dataDirectory"], str(data))
        self.assertEqual(
            self.run_environment_fixture(self.app(changed))["HOME"], str(data / "home")
        )
        self.cli("verify", self.app(changed))
        saved = data / "home" / "user-data.txt"
        saved.write_text("preserve me")
        self.cli("remove", self.app(changed))
        self.assertEqual(saved.read_text(), "preserve me")

    def test_adv_clone_rejects_invalid_configuration_without_mutation(self):
        record = self.create(icon=False)
        app = self.app(record)
        before = digest_tree(self.root)
        for options, code in [
            (["--proxy", "socks5://127.0.0.1:1080"], "invalid_proxy"),
            (["--proxy", "http://host:99999"], "invalid_proxy"),
            (["--locale", "bad\nlocale"], "invalid_locale"),
            (["--app-language", ""], "invalid_app_language"),
            (["--app-language", "zh_CN.UTF-8"], "invalid_app_language"),
            (["--app-language", "en\n"], "invalid_app_language"),
            (["--app-language", 'en");abort();//'], "invalid_app_language"),
            (["--app-language", "a" * 129], "invalid_app_language"),
            (["--data-dir", self.root], "invalid_data_directory"),
            (["--data-dir", self.root / "pending.json"], "invalid_data_directory"),
            (["--data-dir", app / "data"], "invalid_data_directory"),
            (["--reset", "--locale", "C"], "usage"),
            (["--reset", "--app-language", "en"], "usage"),
            (["--locale", "--lang", "--lang", "en"], "invalid_locale"),
            (["--app-language", "--lang", "--lang", "en"], "invalid_app_language"),
        ]:
            with self.subTest(options=options):
                self.assertEqual(
                    self.cli("adv-clone", app, *options, success=False)["code"], code
                )
                self.assertEqual(digest_tree(self.root), before)
        directory = self.directory / "linked-data"
        directory.mkdir()
        (directory / "home").symlink_to(self.directory, target_is_directory=True)
        self.assertEqual(
            self.cli("adv-clone", app, "--data-dir", directory, success=False)["code"],
            "invalid_path",
        )
        self.assertEqual(digest_tree(self.root), before)

    def test_adv_clone_compile_failure_preserves_installed_clone(self):
        self.use_environment_fixture()
        record = self.create(icon=False)
        before = digest_tree(self.root)
        data = self.directory / "data"
        result = subprocess.run(
            [
                str(CLI),
                "adv-clone",
                str(self.app(record)),
                "--data-dir",
                str(data),
                "--json",
            ],
            env={**os.environ, "DEVELOPER_DIR": str(self.directory / "missing-xcode")},
            capture_output=True,
            text=True,
            timeout=45,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stderr)["code"], "command_failed")
        self.assertFalse(data.exists())
        self.assertEqual(digest_tree(self.root), before)
        self.assert_clean()

    def test_adv_clone_rejects_unmanaged_library_and_unsupported_executable(self):
        record = self.create(icon=False)
        app = self.app(record)
        library = app / "Contents/Frameworks/libappclone_env.dylib"
        library.parent.mkdir()
        library.write_bytes(b"unmanaged library")
        before = digest_tree(self.root)
        self.assertEqual(
            self.cli("adv-clone", app, "--locale", "C", success=False)["code"],
            "environment_conflict",
        )
        self.assertEqual(digest_tree(self.root), before)
        library.unlink()
        (app / "Contents/MacOS/fixture").write_text("#!/bin/sh\nexit 0\n")
        before = digest_tree(self.root)
        self.assertEqual(
            self.cli("adv-clone", app, "--locale", "C", success=False)["code"],
            "unsupported_macho",
        )
        self.assertEqual(digest_tree(self.root), before)
        self.assert_clean()

    def localized_cli(self, *arguments, locale="en_US.UTF-8"):
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in {"LC_ALL", "LC_MESSAGES", "LANG"}
        }
        env["LANG"] = locale
        return subprocess.run(
            [str(CLI), *map(str, arguments)],
            env=env,
            capture_output=True,
            text=True,
            timeout=45,
        )

    def test_language_help_and_environment(self):
        for language, phrase, locale in [
            ("zh", "用法：", "en_US.UTF-8"),
            ("en", "Usage:", "zh_CN.UTF-8"),
        ]:
            for arguments in [
                ["--lang", language, "help"],
                ["help", "--lang", language],
                ["--help", "--lang", language],
                ["--lang", language],
            ]:
                result = self.localized_cli(*arguments, locale=locale)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(phrase, result.stdout)
                self.assertIn("--lang zh|en", result.stdout)
        for locale, phrase in [
            ("zh_CN.UTF-8", "用法："),
            ("zh-Hans", "用法："),
            ("en_US.UTF-8", "Usage:"),
            ("fr_FR.UTF-8", "Usage:"),
            ("C", "Usage:"),
        ]:
            self.assertIn(phrase, self.localized_cli("help", locale=locale).stdout)

    def test_language_option_validation_and_literal_arguments(self):
        for args in [["--lang"], ["--lang", "fr"], ["--lang", "en", "--lang", "zh"]]:
            result = self.localized_cli("version", "--json", *args)
            self.assertNotEqual(result.returncode, 0)
            error = json.loads(result.stderr)
            self.assertEqual(error["code"], "usage")
            self.assertIn("--lang", error["message"])
        result = self.localized_cli(
            "clone",
            self.source,
            "--name",
            "--lang",
            "--workspace",
            self.root,
            "--lang",
            "en",
            "--json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["name"], "--lang")
        result = self.localized_cli(
            "rename",
            "--lang",
            "en",
            "--",
            self.app(record),
            "--lang",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["name"], "--lang")

    def test_language_errors_keep_codes_and_json_shape(self):
        for language, prefix, fragment in [
            ("zh", "错误：", "请选择 macOS"),
            ("en", "Error:", "Choose a macOS"),
        ]:
            result = self.localized_cli("inspect", self.directory, "--lang", language)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(result.stderr.startswith(prefix))
            self.assertIn(fragment, result.stderr)
            result = self.localized_cli(
                "inspect",
                self.directory,
                "--lang",
                language,
                "--json",
            )
            error = json.loads(result.stderr)
            self.assertEqual(set(error), {"code", "message"})
            self.assertEqual(error["code"], "not_app")
            self.assertIn(fragment, error["message"])
            self.assertEqual(result.stdout, "")
            result = self.localized_cli("bogus", "--lang", language, "--json")
            self.assertEqual(json.loads(result.stderr)["code"], "usage")
            self.assertIn("bogus", json.loads(result.stderr)["message"])

    def test_language_progress_list_stats_and_stable_records(self):
        for language, saved in [("zh", "分身已保存"), ("en", "Clone saved")]:
            result = self.localized_cli(
                "clone",
                self.source,
                "--name",
                "工作 " + language,
                "--icon",
                self.red,
                "--workspace",
                self.root,
                "--lang",
                language,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[complete] " + saved, result.stderr)
            self.assertEqual(json.loads(result.stdout)["source"]["name"], "原应用")
        state_before = (self.root / "state.json").read_bytes()
        for command, phrases in [
            ("list", ("自定义图标", "Custom icon")),
            ("stats", ("累计创建：2", "Total created: 2")),
        ]:
            outputs = []
            for language, phrase in zip(["zh", "en"], phrases):
                result = self.localized_cli(
                    command,
                    "--workspace",
                    self.root,
                    "--lang",
                    language,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(phrase, result.stdout)
                result = self.localized_cli(
                    command,
                    "--workspace",
                    self.root,
                    "--lang",
                    language,
                    "--json",
                )
                self.assertEqual(result.stderr, "")
                outputs.append(json.loads(result.stdout))
            self.assertEqual(*outputs)
        self.assertEqual((self.root / "state.json").read_bytes(), state_before)

    def test_language_empty_workspace(self):
        for command, phrases in [
            ("list", ("还没有分身。", "No clones yet.")),
            ("stats", ("暂无分身创建记录。", "No clone creation history yet.")),
        ]:
            for language, phrase in zip(["zh", "en"], phrases):
                result = self.localized_cli(
                    command,
                    "--workspace",
                    self.root,
                    "--lang",
                    language,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), phrase)

    def test_path_commands_infer_workspace_and_follow_symlinks(self):
        record = self.create(name="微信 工作")
        app = self.app(record)
        shortcut = self.directory / "分身入口.app"
        shortcut.symlink_to(app)
        self.assertEqual(
            self.cli("verify", shortcut, workspace=False)["id"], record["id"]
        )
        changed = self.cli("icon", shortcut, self.blue, workspace=False)
        self.assertNotEqual(changed["customIconSHA256"], record["customIconSHA256"])
        renamed = self.cli("rename", shortcut, "微信2", workspace=False)
        self.assertEqual(renamed["id"], record["id"])
        self.assertTrue(self.app(renamed).exists())
        self.assertFalse(app.exists())
        self.assertEqual(
            self.cli("verify", self.app(renamed), workspace=False)["name"], "微信2"
        )
        listing = subprocess.check_output(
            [str(CLI), "list", "--workspace", str(self.root)],
            text=True,
        )
        self.assertIn("微信2", listing)
        self.assertIn(str(self.app(renamed)), listing)
        self.assertNotIn(record["id"], listing)
        shortcut.unlink()
        shortcut.symlink_to(self.app(renamed))
        removed = self.cli("remove", shortcut, workspace=False)
        self.assertEqual(removed["id"], record["id"])
        self.assertFalse(self.app(renamed).exists())
        self.assertEqual(self.cli("list"), [])
        self.assertEqual(digest_tree(self.source), self.original)
        self.assert_clean()

    def test_path_commands_reject_original_unmanaged_and_wrong_workspace(self):
        record = self.create(icon=False)
        app = self.app(record)
        original_workspace = self.root
        self.root = self.directory / "another-workspace"
        self.create(icon=False)
        before = digest_tree(self.directory)
        error = self.cli("remove", app, success=False)
        self.assertEqual(error["code"], "not_managed")
        self.assertEqual(digest_tree(self.directory), before)
        self.root = original_workspace
        error = self.cli("remove", self.source, success=False, workspace=False)
        self.assertEqual(error["code"], "not_managed")
        unknown = self.root / "apps/unmanaged.app"
        shutil.copytree(self.source, unknown)
        unknown_content = digest_tree(unknown)
        error = self.cli("remove", unknown, success=False, workspace=False)
        self.assertEqual(error["code"], "not_managed")
        self.assertEqual(digest_tree(unknown), unknown_content)
        self.assertTrue(app.exists())
        self.assertEqual(digest_tree(self.source), self.original)
        self.cli("verify", app, workspace=False)
        self.assert_clean()

    def test_doctor_and_read_only_inspection(self):
        tools = self.cli("doctor")
        self.assertTrue(all(tool["available"] for tool in tools))
        result = self.cli("inspect", self.source)
        self.assertEqual(result["bundleID"], self.info["CFBundleIdentifier"])
        self.assertFalse(self.root.exists())
        self.assertEqual(digest_tree(self.source), self.original)

    def test_create_icon_and_signatures(self):
        record = self.create()
        app = self.app(record)
        self.assertEqual(app.name, "微信工作测试.app")
        self.assertEqual(record["appFileName"], app.name)
        self.assertEqual(
            json.loads((self.root / "state.json").read_text())["schemaVersion"], 3
        )
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        self.assertNotEqual(info["CFBundleIdentifier"], self.info["CFBundleIdentifier"])
        self.assertEqual(info["CFBundleDisplayName"], record["name"])
        self.assertEqual(info["CFBundleIconFile"], "app-clone.icns")
        self.assertNotIn("CFBundleIconName", info)
        localized = plistlib.loads(
            (app / "Contents/Resources/zh.lproj/InfoPlist.strings").read_bytes()
        )
        self.assertNotIn("CFBundleDisplayName", localized)
        self.assertNotIn("CFBundleIconName", localized)
        self.assertEqual(
            hashlib.sha256(self.icon_path(record).read_bytes()).hexdigest(),
            record["customIconSHA256"],
        )
        self.cli("verify", self.app(record))
        self.assertEqual(digest_tree(self.source), self.original)
        self.assertEqual(record["compatibility"], "unverified")
        self.assert_clean()

    def test_sequential_bundle_ids_and_per_source_creation_statistics(self):
        source_id = "com.tencent.WeWorkMac"
        self.info["CFBundleIdentifier"] = source_id
        self.plist.write_bytes(plistlib.dumps(self.info))
        first = self.create(icon=False, name="企业微信-A")
        second = self.create(icon=False, name="企业微信-B")
        for number, record in enumerate([first, second], 1):
            self.assertEqual(record["cloneNumber"], number)
            self.assertEqual(record["bundleID"], f"{source_id}.{number}.{record['id']}")
            self.cli("verify", self.app(record))
        self.cli("remove", self.app(first))
        third = self.create(icon=False, name="企业微信-C")
        self.assertEqual(third["cloneNumber"], 3)
        self.info["CFBundleIdentifier"] = "com.tencent.QQ"
        self.plist.write_bytes(plistlib.dumps(self.info))
        other = self.create(icon=False, name="QQ-A")
        self.assertEqual(other["cloneNumber"], 1)
        stats = {item["sourceBundleID"]: item for item in self.cli("stats")}
        self.assertEqual(stats[source_id]["totalCreated"], 3)
        self.assertEqual(stats[source_id]["currentCount"], 2)
        self.assertTrue(stats[source_id]["historyComplete"])
        self.assertEqual(stats["com.tencent.QQ"]["totalCreated"], 1)
        self.root = self.directory / "another-workspace"
        self.assertEqual(self.create(icon=False)["cloneNumber"], 1)

    def test_failed_creates_and_icon_changes_do_not_consume_numbers(self):
        first = self.create()
        statistics = self.cli("stats")
        bad = self.directory / "bad.png"
        bad.write_text("not an image")
        self.cli("create", self.source, "--name", "失败", "--icon", bad, success=False)
        self.cli("create", self.source, "--name", first["name"], success=False)
        self.assertEqual(self.cli("stats"), statistics)
        changed = self.cli("icon", self.app(first), self.blue)
        renamed = self.cli("rename", self.app(first), "改名后")
        for record in [changed, renamed]:
            self.assertEqual(record["cloneNumber"], 1)
            self.assertEqual(record["bundleID"], first["bundleID"])
        self.assertEqual(self.cli("stats"), statistics)
        self.cli("remove", self.app(renamed))
        self.assertEqual(self.cli("stats")[0]["totalCreated"], 1)
        self.assertEqual(self.cli("stats")[0]["currentCount"], 0)
        self.assertEqual(self.create()["cloneNumber"], 2)
        self.assert_clean()

    def test_legacy_creation_count_survives_last_clone_removal(self):
        record = self.make_legacy(self.create(icon=False))
        original_id = record["bundleID"]
        statistics = self.cli("stats")[0]
        self.assertEqual(statistics["totalCreated"], 1)
        self.assertEqual(statistics["currentCount"], 1)
        self.assertFalse(statistics["historyComplete"])
        self.assertEqual(self.cli("verify", self.app(record))["bundleID"], original_id)
        self.cli("remove", self.app(record))
        self.assertEqual(self.cli("stats")[0]["totalCreated"], 1)
        new = self.create(icon=False)
        self.assertEqual(new["cloneNumber"], 2)
        self.assertEqual(self.cli("stats")[0]["totalCreated"], 2)
        self.assertFalse(self.cli("stats")[0]["historyComplete"])
        self.assert_clean()

    def test_creation_statistics_recover_with_install_transaction(self):
        for committed in [False, True]:
            with self.subTest(committed=committed):
                self.root = self.directory / f"recovery-{committed}"
                self.create(icon=False, name="第一个")
                catalog_path = self.root / "state.json"
                before = json.loads(catalog_path.read_text())
                second = self.create(icon=False, name="第二个")
                after = json.loads(catalog_path.read_text())
                if not committed:
                    catalog_path.write_text(json.dumps(before))
                operation = str(uuid.uuid4())
                (self.root / "staging" / operation).mkdir()
                (self.root / "pending.json").write_text(
                    json.dumps(
                        {
                            "operationID": operation,
                            "cloneID": second["id"],
                            "before": before,
                            "after": after,
                        }
                    )
                )
                expected = 2 if committed else 1
                statistics = self.cli("stats")[0]
                self.assertEqual(statistics["totalCreated"], expected)
                self.assertEqual(statistics["currentCount"], expected)
                self.assertEqual(self.app(second).exists(), committed)
                self.assertEqual(
                    self.create(icon=False, name="下一个")["cloneNumber"], expected + 1
                )
                self.assert_clean()

    def test_invalid_counts_and_oversized_bundle_ids_are_rejected(self):
        record = self.create(icon=False)
        catalog_path = self.root / "state.json"
        original = json.loads(catalog_path.read_text())
        source_id = record["source"]["bundleID"]
        for count in [-1, 0, None]:
            with self.subTest(count=count):
                catalog = json.loads(json.dumps(original))
                if count is None:
                    del catalog["creationCounts"]
                else:
                    catalog["creationCounts"][source_id]["totalCreated"] = count
                content = json.dumps(catalog)
                catalog_path.write_text(content)
                self.assertEqual(
                    self.cli("stats", success=False)["code"], "invalid_state"
                )
                self.assertEqual(catalog_path.read_text(), content)
        self.root = self.directory / "long-bundle-id"
        self.info["CFBundleIdentifier"] = "com." + "a" * 214
        self.plist.write_bytes(plistlib.dumps(self.info))
        error = self.cli("create", self.source, "--name", "过长标识", success=False)
        self.assertEqual(error["code"], "invalid_bundle_id")
        self.assertEqual(self.cli("stats"), [])
        self.assert_clean()

    def test_all_icon_sizes_are_exportable(self):
        record = self.create()
        output = self.directory / "export.iconset"
        subprocess.run(
            [
                "/usr/bin/iconutil",
                "-c",
                "iconset",
                "-o",
                str(output),
                str(self.icon_path(record)),
            ],
            check=True,
            capture_output=True,
        )
        for points in (16, 32, 128, 256, 512):
            for suffix in ("", "@2x"):
                self.assertTrue(
                    (output / f"icon_{points}x{points}{suffix}.png").is_file()
                )

    def test_replace_icon_preserves_installed_version_and_identity(self):
        record = self.create()
        self.info["CFBundleShortVersionString"] = "2.0"
        self.info["CFBundleVersion"] = "2"
        self.plist.write_bytes(plistlib.dumps(self.info))
        changed = self.cli("icon", self.app(record), self.blue)
        self.assertNotEqual(changed["customIconSHA256"], record["customIconSHA256"])
        self.assertEqual(changed["bundleID"], record["bundleID"])
        self.assertEqual(changed["source"], record["source"])
        self.assertEqual(changed["createdAt"], record["createdAt"])
        installed = plistlib.loads(
            (self.app(record) / "Contents/Info.plist").read_bytes()
        )
        self.assertEqual(
            installed["CFBundleShortVersionString"], record["source"]["version"]
        )
        self.assertEqual(installed["CFBundleVersion"], record["source"]["build"])
        self.assertEqual(len(self.cli("list")), 1)
        self.cli("verify", self.app(record))
        self.assert_clean()

    def test_icns_input_and_missing_source_icon_replacement(self):
        record = self.create()
        custom = self.directory / "existing.icns"
        shutil.copy2(self.icon_path(record), custom)
        renamed = self.directory / "renamed.app"
        self.source.rename(renamed)
        changed = self.cli("icon", self.app(record), custom)
        self.assertEqual(changed["customIconSHA256"], record["customIconSHA256"])
        self.cli("verify", self.app(record))
        self.assertEqual(digest_tree(renamed), self.original)

    def test_jpeg_input(self):
        jpg = self.directory / "sample.jpg"
        subprocess.run(
            ["/usr/bin/sips", "-s", "format", "jpeg", str(self.red), "--out", str(jpg)],
            check=True,
            capture_output=True,
        )
        record = self.cli("create", self.source, "--name", "jpeg图标", "--icon", jpg)
        self.assertIsNotNone(record["customIconSHA256"])
        self.cli("verify", self.app(record))

    def test_bad_icon_preserves_installed_bundle(self):
        record = self.create()
        before = digest_tree(self.app(record))
        bad = self.directory / "bad.png"
        bad.write_text("not an image")
        error = self.cli("icon", self.app(record), bad, success=False)
        self.assertEqual(error["code"], "invalid_icon")
        self.assertEqual(digest_tree(self.app(record)), before)
        self.assertEqual(self.cli("list")[0], record)
        self.assert_clean()

    def test_verify_rejects_changed_custom_icon(self):
        record = self.create()
        other = self.cli("create", self.source, "--name", "其他", "--icon", self.blue)
        self.icon_path(record).write_bytes(self.icon_path(other).read_bytes())
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(self.app(record))],
            check=True,
            capture_output=True,
        )
        before = digest_tree(self.app(record))
        error = self.cli("verify", self.app(record), success=False)
        self.assertEqual(error["code"], "icon_changed")
        self.assertEqual(digest_tree(self.app(record)), before)
        self.assert_clean()

    def test_display_name_is_never_executed_as_shell(self):
        injected = self.directory / "should-not-exist"
        name = f"测试'; $(touch {injected})"
        record = self.create(icon=False, name=name[:80])
        self.assertEqual(record["name"], name[:80])
        self.assertFalse(injected.exists())
        self.assertEqual(self.app(record).parent, self.root / "apps")
        self.cli("verify", self.app(record))

    def test_readable_names_handle_separators_collisions_and_long_unicode(self):
        first = self.create(icon=False, name="工作/微信")
        second = self.create(icon=False, name="工作:微信")
        self.assertEqual(first["appFileName"], "工作-微信.app")
        self.assertTrue(second["appFileName"].startswith("工作-微信 ("))
        self.assertNotEqual(self.app(first), self.app(second))
        for name in ["🙂" * 80, "../外部", "..."]:
            record = self.create(icon=False, name=name)
            self.assertEqual(record["name"], name)
            self.assertLessEqual(len(record["appFileName"].encode()), 255)
            self.assertFalse(record["appFileName"].startswith("."))
            self.assertEqual(self.app(record).parent, self.root / "apps")
            self.cli("verify", self.app(record))
        self.assert_clean()

    def test_name_collision_does_not_overwrite_unrelated_file_or_symlink(self):
        self.cli("list")
        unrelated = self.root / "apps" / "冲突.app"
        unrelated.write_text("keep")
        record = self.create(icon=False, name="冲突")
        self.assertNotEqual(self.app(record), unrelated)
        self.assertEqual(unrelated.read_text(), "keep")
        target = self.directory / "external.app"
        link = self.root / "apps" / "链接.app"
        link.symlink_to(target)
        other = self.create(icon=False, name="链接")
        self.assertNotEqual(self.app(other), link)
        self.assertTrue(link.is_symlink())
        self.assertFalse(target.exists())

    def test_rename_preserves_identity_icon_and_version_without_source(self):
        record = self.create(name="微信工作")
        old_path = self.app(record)
        old_icon = self.icon_path(record).read_bytes()
        executable_before = self.directory / "before.bin"
        shutil.copy2(old_path / "Contents/MacOS/fixture", executable_before)
        statistics = self.cli("stats")
        renamed_source = self.directory / "source-moved.app"
        self.source.rename(renamed_source)
        renamed = self.cli("rename", self.app(record), "微信2")
        self.assertEqual(renamed["name"], "微信2")
        self.assertEqual(renamed["appFileName"], "微信2.app")
        for key in [
            "id",
            "bundleID",
            "cloneNumber",
            "source",
            "createdAt",
            "customIconSHA256",
        ]:
            self.assertEqual(renamed[key], record[key])
        self.assertFalse(old_path.exists())
        info = plistlib.loads((self.app(renamed) / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleName"], "微信2")
        self.assertEqual(info["CFBundleDisplayName"], "微信2")
        self.assertEqual(
            info["CFBundleShortVersionString"], record["source"]["version"]
        )
        executable_after = self.directory / "after.bin"
        shutil.copy2(self.app(renamed) / "Contents/MacOS/fixture", executable_after)
        # Renaming changes the embedded signature; compare the unsigned executable code.
        for executable in [executable_before, executable_after]:
            subprocess.run(
                ["/usr/bin/codesign", "--remove-signature", str(executable)],
                check=True,
                capture_output=True,
            )
        self.assertEqual(executable_before.read_bytes(), executable_after.read_bytes())
        self.assertEqual(self.icon_path(renamed).read_bytes(), old_icon)
        self.assertEqual(self.cli("stats"), statistics)
        self.cli("verify", self.app(renamed))
        self.assertEqual(self.cli("rename", self.app(renamed), "微信2"), renamed)
        self.cli("remove", self.app(renamed))
        self.assertFalse(self.app(renamed).exists())
        self.assertEqual(digest_tree(renamed_source), self.original)
        self.assert_clean()

    def test_rename_preserves_occupied_destination(self):
        record = self.create(icon=False)
        occupied = self.root / "apps/微信2.app"
        occupied.mkdir()
        sentinel = occupied / "keep"
        sentinel.write_text("unrelated")
        renamed = self.cli("rename", self.app(record), "微信2")
        self.assertEqual(renamed["name"], "微信2")
        self.assertNotEqual(self.app(renamed), occupied)
        self.assertEqual(sentinel.read_text(), "unrelated")
        self.cli("verify", self.app(renamed))
        self.assert_clean()

    def test_rename_rejects_invalid_and_duplicate_names(self):
        record = self.create()
        self.create(icon=False, name="occupied")
        before = digest_tree(self.root)
        for name, code in [
            ("", "invalid_name"),
            ("a\nb", "invalid_name"),
            ("a" * 81, "invalid_name"),
            ("OCCUPIED", "name_conflict"),
        ]:
            with self.subTest(name=name):
                error = self.cli("rename", self.app(record), name, success=False)
                self.assertEqual(error["code"], code)
                self.assertEqual(digest_tree(self.root), before)
                self.assert_clean()

    def test_rename_reuses_case_only_and_sanitized_filenames(self):
        for first, second, filename in [
            ("CaseName", "casename", "casename.app"),
            ("工作/微信", "工作:微信", "工作-微信.app"),
        ]:
            with self.subTest(name=second):
                self.root = self.directory / str(uuid.uuid4())
                record = self.create(icon=False, name=first)
                renamed = self.cli("rename", self.app(record), second)
                self.assertEqual(renamed["appFileName"], filename)
                self.assertEqual(len(list((self.root / "apps").iterdir())), 1)
                self.cli("verify", self.app(renamed))
                self.assert_clean()

    def test_rename_failure_preserves_original_bundle_and_statistics(self):
        record = self.create()
        other = self.create(name="另一个")
        self.cli("icon", self.app(other), self.blue)
        self.icon_path(record).write_bytes(self.icon_path(other).read_bytes())
        before = digest_tree(self.root)
        error = self.cli("rename", self.app(record), "失败改名", success=False)
        self.assertEqual(error["code"], "icon_changed")
        self.assertEqual(digest_tree(self.root), before)
        self.assertFalse((self.root / "apps/失败改名.app").exists())
        self.assert_clean()

    def test_interrupted_rename_recovers_bundle_and_catalog(self):
        for phase in ["prepared", "backed_up", "installed", "committed"]:
            with self.subTest(phase=phase):
                self.root = self.directory / phase
                record = self.create(name="微信工作")
                snapshot = self.directory / (phase + ".app")
                shutil.copytree(self.app(record), snapshot)
                old_content = digest_tree(snapshot)
                catalog_path = self.root / "state.json"
                before = json.loads(catalog_path.read_text())
                renamed = self.cli("rename", self.app(record), "微信2")
                new_content = digest_tree(self.app(renamed))
                after = json.loads(catalog_path.read_text())
                operation = str(uuid.uuid4())
                job = self.root / "staging" / operation
                job.mkdir()
                self.app(renamed).rename(job / "candidate.app")
                shutil.copytree(snapshot, self.app(record))
                catalog_path.write_text(json.dumps(before))
                if phase != "prepared":
                    self.app(record).rename(job / "previous.app")
                if phase in ["installed", "committed"]:
                    (job / "candidate.app").rename(self.app(renamed))
                if phase == "committed":
                    catalog_path.write_text(json.dumps(after))
                (self.root / "pending.json").write_text(
                    json.dumps(
                        {
                            "operationID": operation,
                            "cloneID": record["id"],
                            "before": before,
                            "after": after,
                        }
                    )
                )
                expected = renamed if phase == "committed" else record
                expected_content = new_content if phase == "committed" else old_content
                self.assertEqual(self.cli("list"), [expected])
                self.assertEqual(digest_tree(self.app(expected)), expected_content)
                self.assertEqual(len(list((self.root / "apps").iterdir())), 1)
                self.cli("verify", self.app(expected))
                self.assert_clean()

    def test_interrupted_name_repair_recovers_before_and_after_catalog_commit(self):
        for phase in ["before_move", "after_move", "after_catalog"]:
            with self.subTest(phase=phase):
                self.root = self.directory / phase
                record = self.make_legacy(self.create(icon=False))
                original = digest_tree(self.app(record))
                catalog_path = self.root / "state.json"
                before = json.loads(catalog_path.read_text())
                after = json.loads(json.dumps(before))
                after["schemaVersion"] = 2
                after["revision"] = str(uuid.uuid4())
                after["clones"][0]["appFileName"] = "微信工作测试.app"
                operation = str(uuid.uuid4())
                (self.root / "staging" / operation).mkdir()
                if phase != "before_move":
                    self.app(record).rename(self.app(after["clones"][0]))
                if phase == "after_catalog":
                    catalog_path.write_text(json.dumps(after))
                (self.root / "pending.json").write_text(
                    json.dumps(
                        {
                            "operationID": operation,
                            "cloneID": record["id"],
                            "before": before,
                            "after": after,
                            "relocation": True,
                        }
                    )
                )
                expected = after if phase == "after_catalog" else before
                self.assertEqual(self.cli("list"), expected["clones"])
                self.assertEqual(digest_tree(self.app(expected["clones"][0])), original)
                self.assertEqual(len(list((self.root / "apps").iterdir())), 1)
                self.cli("verify", self.app(expected["clones"][0]))
                self.assert_clean()

    def test_catalog_app_filename_cannot_escape_workspace(self):
        record = self.create(icon=False)
        original = digest_tree(self.app(record))
        catalog_path = self.root / "state.json"
        catalog = json.loads(catalog_path.read_text())
        for filename in ["../external.app", "/tmp/external.app", "bad:name.app"]:
            with self.subTest(filename=filename):
                catalog["clones"][0]["appFileName"] = filename
                catalog_path.write_text(json.dumps(catalog))
                error = self.cli("remove", self.app(record), success=False)
                self.assertEqual(error["code"], "invalid_state")
                self.assertEqual(digest_tree(self.app(record)), original)

    def test_conflicting_names_and_remove_only_owned_clone(self):
        record = self.create()
        error = self.cli("create", self.source, "--name", record["name"], success=False)
        self.assertEqual(error["code"], "name_conflict")
        unrelated = self.root / "unrelated-user-data"
        unrelated.write_text("keep")
        self.cli("remove", self.app(record))
        self.assertEqual(self.cli("list"), [])
        self.assertFalse(self.app(record).exists())
        self.assertEqual(unrelated.read_text(), "keep")
        self.assertEqual(digest_tree(self.source), self.original)
        self.assert_clean()

    def test_ownership_mismatch_refuses_mutation(self):
        record = self.create(icon=False)
        plist = self.app(record) / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["appclone_id"] = str(uuid.uuid4())
        plist.write_bytes(plistlib.dumps(info))
        error = self.cli("remove", self.app(record), success=False)
        self.assertEqual(error["code"], "ownership_mismatch")
        self.assertTrue(self.app(record).exists())
        self.assertEqual(len(self.cli("list")), 1)

    def test_external_symlink_is_rejected(self):
        outside = self.directory / "outside"
        outside.write_text("unchanged")
        (self.source / "Contents/Resources/external").symlink_to(outside)
        error = self.cli("create", self.source, "--name", "链接测试", success=False)
        self.assertEqual(error["code"], "external_symlink")
        self.assertEqual(outside.read_text(), "unchanged")
        self.assertEqual(self.cli("list"), [])
        self.assert_clean()

    def test_workspace_cannot_be_inside_source(self):
        self.root = self.source / "workspace"
        error = self.cli("create", self.source, "--name", "路径测试", success=False)
        self.assertEqual(error["code"], "overlapping_paths")
        self.assertFalse(self.root.exists())

    def test_invalid_state_is_not_reset(self):
        self.cli("list")
        state = self.root / "state.json"
        state.write_text("{ broken")
        error = self.cli("list", success=False)
        self.assertEqual(error["code"], "invalid_state")
        self.assertEqual(state.read_text(), "{ broken")

    def test_failed_signature_does_not_install(self):
        (self.source / "Contents/Frameworks/broken.app/Contents").mkdir(parents=True)
        error = self.cli("create", self.source, "--name", "损坏程序", success=False)
        self.assertEqual(error["code"], "command_failed")
        self.assertEqual(self.cli("list"), [])
        self.assertEqual(list((self.root / "apps").iterdir()), [])
        self.assert_clean()

    def test_copy_failure_cleans_staging_and_preserves_source_and_installed_clone(self):
        record = self.create(icon=False)
        installed = digest_tree(self.app(record))
        statistics = self.cli("stats")
        denied = self.source / "Contents/Resources/unreadable.dat"
        denied.write_bytes(b"copy failure fixture")
        original = digest_tree(self.source)
        permissions = denied.stat().st_mode & 0o777
        try:
            denied.chmod(0)
            error = self.cli(
                "create", self.source, "--name", "复制失败测试", success=False
            )
            self.assertEqual(error["code"], "command_failed")
            self.assertIn("ditto", error["message"])
            self.assertEqual(digest_tree(self.app(record)), installed)
            self.assertEqual(self.cli("list"), [record])
            self.assertEqual(self.cli("stats"), statistics)
            self.assert_clean()
        finally:
            denied.chmod(permissions)
        self.assertEqual(digest_tree(self.source), original)

    def test_interrupted_install_restores_previous_bundle(self):
        record = self.create()
        original_bundle = digest_tree(self.app(record))
        before = json.loads((self.root / "state.json").read_text())
        after = json.loads(json.dumps(before))
        after["revision"] = str(uuid.uuid4())
        operation = str(uuid.uuid4())
        job = self.root / "staging" / operation
        job.mkdir()
        shutil.move(self.app(record), job / "previous.app")
        shutil.copytree(job / "previous.app", self.app(record))
        (self.app(record) / "Contents/Resources/partial").write_text("unfinished")
        (self.root / "pending.json").write_text(
            json.dumps(
                {
                    "operationID": operation,
                    "cloneID": record["id"],
                    "before": before,
                    "after": after,
                }
            )
        )
        self.assertEqual(self.cli("list")[0], record)
        self.assertEqual(digest_tree(self.app(record)), original_bundle)
        self.cli("verify", self.app(record))
        self.assert_clean()

    def test_symlinked_state_is_rejected(self):
        self.cli("list")
        external = self.directory / "external.json"
        external.write_text("{}")
        (self.root / "state.json").symlink_to(external)
        error = self.cli("list", success=False)
        self.assertEqual(error["code"], "invalid_path")
        self.assertEqual(external.read_text(), "{}")


if __name__ == "__main__":
    unittest.main()
