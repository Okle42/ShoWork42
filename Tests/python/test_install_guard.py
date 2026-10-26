"""showork_install.py 的安裝版本守門（10-25）。跑法：python3 -m unittest discover -s Tests/python"""
import importlib.util, os, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("inst", os.path.join(ROOT, "scripts/showork_install.py"))
inst = importlib.util.module_from_spec(spec); spec.loader.exec_module(inst)

# 假歷史：a ← b ← c（main）；b ← x（別的分支）
PARENT = {"b": "a", "c": "b", "x": "b"}
def anc(a, b):
    while b:
        if a == b: return True
        b = PARENT.get(b)
    return False

class InstallCheck(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(inst.install_check("c", None, "c", anc), [])          # 第一次裝
        self.assertEqual(inst.install_check("c", "b", "c", anc), [])           # 比已安裝的新
        self.assertEqual(inst.install_check("c", "c", "c", anc), [])           # 重裝同一個

    def test_older_than_installed(self):
        why = inst.install_check("b", "c", "b", anc)
        self.assertEqual(len(why), 1); self.assertIn("不包含", why[0])

    def test_missing_main(self):
        why = inst.install_check("x", "b", "c", anc)                            # worktree 落後 main
        self.assertTrue(any("main" in w for w in why))

    def test_other_branch_than_installed(self):
        self.assertEqual(len(inst.install_check("c", "x", "c", anc)), 1)       # 已安裝的在別的分支

    def test_no_head(self):
        self.assertEqual(len(inst.install_check("", None, "c", anc)), 1)

if __name__ == "__main__":
    unittest.main()
