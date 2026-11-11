"""Run-scoped evidence paths and fail-before-write receipts."""
import json
import os
import pathlib
import re

RUN_NAME = re.compile(r'^\d{8}-\d{6}(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?$')


def _is_reparse(path):
    return path.is_symlink() or (path.exists() and path.is_junction())


class RunEvidence:
    def __init__(self, root):
        supplied = pathlib.Path(root)
        if not supplied.is_absolute() or '..' in supplied.parts or not RUN_NAME.fullmatch(supplied.name):
            raise ValueError('invalid-run-directory')
        if not supplied.is_dir():
            raise ValueError('run-directory-not-found')
        for item in (supplied, *supplied.parents):
            if _is_reparse(item):
                raise ValueError('reparse-evidence')
        self.root = supplied.resolve()

    def output_path(self, name):
        supplied = pathlib.Path(name)
        candidate = supplied if supplied.is_absolute() else self.root / supplied
        candidate = pathlib.Path(os.path.abspath(candidate))
        if not candidate.is_relative_to(self.root):
            raise ValueError('outside-current-run')
        if candidate == self.root or '..' in supplied.parts:
            raise ValueError('invalid-evidence-path')
        for item in (candidate, *candidate.parents):
            if _is_reparse(item):
                raise ValueError('reparse-evidence')
            if item == self.root:
                break
        return candidate

    def write_text_new(self, name, text):
        target = self.output_path(name)
        if target.exists():
            raise ValueError('evidence-already-exists')
        target.parent.mkdir(parents=True, exist_ok=True)
        target = self.output_path(target)
        if target.exists():
            raise ValueError('evidence-already-exists')
        with target.open('x', encoding='utf-8', newline='\n') as stream:
            stream.write(text)
        return target

    def write_json_new(self, name, value):
        return self.write_text_new(name, json.dumps(value, ensure_ascii=False, indent=2) + '\n')
