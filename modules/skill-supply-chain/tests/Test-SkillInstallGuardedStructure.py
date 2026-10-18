#!/usr/bin/env python3
"""Structure tests for the guarded skill installer modules and their deployment closure."""

from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMPLEMENTATION_ROOT = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation"
DEPLOY_SCRIPT = PROJECT_ROOT / "scripts" / "Deploy-SkillInstallGuarded.ps1"
RECONCILE = IMPLEMENTATION_ROOT / "reconcile_skill_source_records.py"
ENTRY = "install_skill_guarded"
MODULE_PREFIX = "install_skill_guarded_"


def parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def installer_modules() -> dict[str, ast.Module]:
    return {path.stem: parse(path) for path in sorted(IMPLEMENTATION_ROOT.glob(f"{MODULE_PREFIX}*.py"))}


def installer_imports(tree: ast.Module) -> list[ast.Import | ast.ImportFrom]:
    return [
        node for node in tree.body
        if (isinstance(node, ast.Import) and any(alias.name.startswith(ENTRY) for alias in node.names))
        or (isinstance(node, ast.ImportFrom) and (node.module or "").startswith(ENTRY))
    ]


def imported_modules(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in installer_imports(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        else:
            names.add(node.module)
    return names


def top_level_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    pending = list(tree.body)
    while pending:
        node = pending.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            names.update((alias.asname or alias.name).split(".")[0] for alias in node.names)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names.update(item.id for target in targets for item in ast.walk(target) if isinstance(item, ast.Name))
        elif isinstance(node, (ast.If, ast.Try)):
            pending.extend(node.body + node.orelse + getattr(node, "finalbody", []))
            pending.extend(statement for handler in getattr(node, "handlers", []) for statement in handler.body)
    return names


class InstallerStructureTests(unittest.TestCase):
    def test_installer_modules_exist(self) -> None:
        self.assertTrue(installer_modules(), "installer modules beside the entry are missing")

    def test_installer_modules_never_import_the_entry(self) -> None:
        for name, tree in installer_modules().items():
            self.assertNotIn(ENTRY, imported_modules(tree), f"{name} imports the installer entry")

    def test_functions_are_reached_through_their_module(self) -> None:
        # Tests patch a function on the module that owns it.  That only intercepts callers that
        # look it up there: ``import install_skill_guarded_x as _x`` and ``_x.function()``.
        modules = installer_modules()
        functions = {
            name: {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
            for name, tree in modules.items()
        }
        for name, tree in {**modules, ENTRY: parse(IMPLEMENTATION_ROOT / f"{ENTRY}.py")}.items():
            for node in installer_imports(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        expected = "_" + alias.name.removeprefix(MODULE_PREFIX)
                        self.assertEqual(alias.asname, expected, f"{name}: import {alias.name}")
                else:
                    for alias in node.names:
                        self.assertNotIn(
                            alias.name,
                            functions.get(node.module, set()),
                            f"{name} imports function {alias.name} from {node.module} by name",
                        )

    def test_module_references_resolve(self) -> None:
        # A stale ``_x.name`` fails only when its line runs, and on a rollback path that can be
        # the first time it is needed.
        modules = installer_modules()
        defined = {name: top_level_names(tree) for name, tree in modules.items()}
        for name, tree in {**modules, ENTRY: parse(IMPLEMENTATION_ROOT / f"{ENTRY}.py")}.items():
            aliases = {
                alias.asname: alias.name
                for node in installer_imports(tree) if isinstance(node, ast.Import)
                for alias in node.names
            }
            for node in ast.walk(tree):
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in aliases:
                    module = aliases[node.value.id]
                    self.assertIn(
                        node.attr, defined.get(module, set()), f"{name}:{node.lineno}: {module} defines no {node.attr}"
                    )

    def test_installer_import_graph_is_acyclic(self) -> None:
        graph = {name: imported_modules(tree) for name, tree in installer_modules().items()}
        state: dict[str, str] = {}

        def visit(name: str, trail: list[str]) -> None:
            state[name] = "visiting"
            for dependency in sorted(graph.get(name, set())):
                self.assertIn(dependency, graph, f"{name} imports missing module {dependency}")
                self.assertNotEqual(
                    state.get(dependency), "visiting", f"import cycle: {' -> '.join(trail + [dependency])}"
                )
                if dependency not in state:
                    visit(dependency, trail + [dependency])
            state[name] = "done"

        for name in graph:
            if name not in state:
                visit(name, [name])

    def test_entry_prepares_imports_before_loading_installer_modules(self) -> None:
        entry = parse(IMPLEMENTATION_ROOT / f"{ENTRY}.py")
        body = entry.body
        bytecode = next(
            index for index, node in enumerate(body)
            if isinstance(node, ast.Assign) and ast.unparse(node.targets[0]) == "sys.dont_write_bytecode"
        )
        path_insert = next(
            index for index, node in enumerate(body)
            if isinstance(node, ast.If) and "sys.path.insert" in ast.unparse(node)
        )
        first_import = min(body.index(node) for node in installer_imports(entry))
        self.assertLess(bytecode, first_import, "bytecode must be off before installer modules load")
        self.assertLess(path_insert, first_import, "the entry directory must be importable first")

    def test_deployment_closure_lists_every_installer_module(self) -> None:
        match = re.search(r"\$sourceFiles = @\((.*?)\n\)", DEPLOY_SCRIPT.read_text(encoding="utf-8"), re.S)
        self.assertIsNotNone(match, "Deploy-SkillInstallGuarded.ps1 $sourceFiles not found")
        deployed = re.findall(r"^\s*'([^']+)',?\s*$", match.group(1), re.M)
        runtime_files = next(
            ast.literal_eval(node.value) for node in parse(RECONCILE).body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "RUNTIME_FILES" for target in node.targets)
        )
        self.assertEqual(list(runtime_files), deployed, "RUNTIME_FILES must match the deployed files")
        entry_index = deployed.index(f"{ENTRY}.py")
        for name in installer_modules():
            self.assertIn(f"{name}.py", deployed, f"{name}.py is not deployed")
            # Modules land before the entry, so the copy never runs a new entry without them.
            self.assertLess(deployed.index(f"{name}.py"), entry_index, f"{name}.py deploys after the entry")


if __name__ == "__main__":
    unittest.main()
