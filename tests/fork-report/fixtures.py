"""Throwaway git repos for the fork report tests: an upstream with an ssh-signed tag and fork
commits on top, like the real forks over a GrapheneOS release tag."""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "..", "scripts"))
FORKS_SH = os.path.join(SCRIPTS, "forks.sh")
ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
           GIT_NO_REPLACE_OBJECTS="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.org",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.org",
           GIT_AUTHOR_DATE="2026-01-01T00:00:00Z", GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
TAG = "2026102100"


def git(d, *args, input=None):
    return subprocess.run(["git", "-C", d, *args], env=ENV, check=True, capture_output=True,
                          input=input).stdout.decode()


def signing_key(tmp):
    """(private key path, allowed signers path) for signing the upstream tag."""
    key = os.path.join(tmp, "key")
    if not os.path.exists(key):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "upstream", "-f", key],
                       check=True)
        with open(key + ".pub") as f:
            pub = f.read().split()
        with open(os.path.join(tmp, "allowed_signers"), "w") as f:
            f.write(f"upstream@example.org namespaces=\"git\" {pub[0]} {pub[1]}\n")
    return key, os.path.join(tmp, "allowed_signers")


def write(d, path, data, mode=None):
    p = os.path.join(d, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    if mode:
        os.chmod(p, mode)


def commit(d, msg):
    git(d, "add", "-A")
    git(d, "commit", "-q", "-m", msg)
    return git(d, "rev-parse", "HEAD").strip()


def patch_id(d, c):
    return subprocess.run(["bash", "-c", 'source "$1"; patch_id "$2" "$3"', "_", FORKS_SH, d, c],
                          env=ENV, check=True, capture_output=True, text=True).stdout.strip()


class Fork:
    """An upstream repo at TAG (signed unless signed=False) with fork commits added by the
    test. approved() gives the approved.txt lines for the fork commits."""

    def __init__(self, tmp, path, name, files, signed=True):
        self.path, self.name = path, name
        self.dir = os.path.join(tmp, name)
        os.makedirs(self.dir)
        git(self.dir, "init", "-q", "-b", "main")
        for p, data in files.items():
            write(self.dir, p, data)
        commit(self.dir, "upstream")
        if signed:
            key, _ = signing_key(tmp)
            git(self.dir, "-c", "gpg.format=ssh", "-c", f"user.signingkey={key}",
                "tag", "-s", "-m", TAG, TAG)
        else:
            git(self.dir, "tag", "-a", "-m", TAG, TAG)
        self.commits = []   # (sha, group, subject)

    def change(self, group, subject, files=(), delete=(), chmod=()):
        for p, data in dict(files).items():
            write(self.dir, p, data)
        for p in delete:
            os.remove(os.path.join(self.dir, p))
        for p in chmod:
            os.chmod(os.path.join(self.dir, p), 0o755)
        c = commit(self.dir, subject)
        self.commits.append((c, group, subject))
        return c

    def head(self):
        return git(self.dir, "rev-parse", "HEAD").strip()

    def approved(self, skip=()):
        out = []
        for c, group, subject in self.commits:
            if c in skip:
                continue
            out.append(f"{self.name} {patch_id(self.dir, c)} {c[:12]} {group} {subject}\n")
        return "".join(out)


def toml(*groups):
    out = []
    for i, g in enumerate(groups):
        out.append(f'[groups.{g}]\norder = {10 * (i + 1)}\ntitle = "{g.title()}"\n'
                   f'what = "What {g} does."\nwhy = "Why {g}."\ndocs = ["04-x.md"]\n')
    return "\n".join(out).encode()
