#!/usr/bin/env python3
"""Generate one high-entropy API bearer credential and its hash registry entry."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import secrets


ALLOWED_ROLES = frozenset({"analyst", "annotator", "admin"})
CREDENTIAL_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Raw token'i bir kez, API ortaminda saklanacak SHA-256 registry "
            "kaydini ayri olarak uretir. Hicbir dosyayi degistirmez."
        )
    )
    parser.add_argument("--credential-id", required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument(
        "--roles",
        default="analyst,annotator,admin",
        help="Virgulle ayrilmis analyst,annotator,admin rolleri",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    credential_id = args.credential_id
    subject = args.subject
    roles = frozenset(part.strip() for part in args.roles.split(",") if part.strip())

    if not CREDENTIAL_ID_PATTERN.fullmatch(credential_id):
        raise SystemExit("credential-id 1-64 karakter ve yalniz A-Z, a-z, 0-9, ., _, - olmali")
    if subject != subject.strip() or not 1 <= len(subject) <= 120:
        raise SystemExit("subject 1-120 karakter olmali ve bas/son bosluk icermemeli")
    if any(ord(character) < 32 or ord(character) == 127 for character in subject):
        raise SystemExit("subject kontrol karakteri iceremez")
    if not roles or not roles <= ALLOWED_ROLES:
        raise SystemExit("roles yalniz analyst,annotator,admin degerlerini icerebilir")

    token = f"adv_pat_v1_{secrets.token_urlsafe(32)}"
    token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
    registry_entry = {
        "credential_id": credential_id,
        "subject": subject,
        "token_sha256": token_hash,
        "roles": sorted(roles),
    }

    print("Raw bearer token (secret manager'a kaydedin; tekrar gosterilmez):")
    print(token)
    print("\nADVISOR_AUTH_PRINCIPALS registry girdisi:")
    print(json.dumps([registry_entry], ensure_ascii=False, separators=(",", ":")))
    print("\nIstek header'i:")
    print('Authorization: Bearer ${ADVISOR_API_TOKEN}')


if __name__ == "__main__":
    main()
