"""Validate the constructor-only Sepolia manifest against its schema and compiler ABIs."""
import copy
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def validate_manifest(manifest, constructors):
    """This stack uses scalar inputs only: one manifest string per ABI argument."""
    if set(manifest) != {"kind", "contracts", "notes"} or manifest["kind"] != "evm_contracts":
        raise ValueError("invalid manifest keys or kind")
    if not isinstance(manifest["notes"], str) or len(manifest["notes"]) > 4000:
        raise ValueError("notes must be a string of at most 4000 characters")
    if not 1 <= len(manifest["contracts"]) <= 8:
        raise ValueError("expected one to eight applications")
    seen = set()
    for contract in manifest["contracts"]:
        if set(contract) != {"contract", "constructorArgs"}:
            raise ValueError("invalid contract keys")
        name, args = contract["contract"], contract["constructorArgs"]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,31}", name) or name in seen:
            raise ValueError("invalid or duplicate contract name")
        constructor = constructors[name]
        if constructor["stateMutability"] != "nonpayable":
            raise ValueError("constructor must be nonpayable")
        fields = constructor["inputs"]
        if not isinstance(args, list) or len(args) != len(fields) or len(args) > 16:
            raise ValueError("constructor argument count mismatch")
        for arg, field in zip(args, fields):
            if not isinstance(arg, str):
                raise ValueError("constructor arguments must be strings")
            if field["type"] not in {"address", "uint256"}:
                raise ValueError("this stack requires scalar constructor inputs")
            if arg == "$owner":
                if field["type"] != "address":
                    raise ValueError("owner must fill an address input")
            elif arg.startswith("$contract:"):
                if field["type"] != "address" or arg.split(":", 1)[1] not in seen:
                    raise ValueError("contract references must be backward address references")
            else:
                if not re.fullmatch(r"(?:[0-9]+|0x[0-9a-fA-F]+)", arg):
                    raise ValueError("expected a static decimal or hex word")
                number = int(arg, 16) if arg.startswith("0x") else int(arg)
                bits = 160 if field["type"] == "address" else 256
                if not 0 <= number < 2**bits:
                    raise ValueError("static word out of range")
        seen.add(name)


class LaunchManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / "launch.json").read_text())
        cls.constructors = {}
        for entry in cls.manifest["contracts"]:
            name = entry["contract"]
            abi = json.loads(subprocess.check_output(["forge", "inspect", name, "abi", "--json"], cwd=ROOT, text=True))
            cls.constructors[name] = next(entry for entry in abi if entry["type"] == "constructor")

    def test_exact_deployment_order_owners_and_dependencies(self):
        validate_manifest(self.manifest, self.constructors)
        expected = [
            ("MockOG", ["$owner"]),
            ("OGClubFurniture", ["$owner", "$owner"]),
            ("OGClubFarmVault", ["$contract:MockOG", "$owner"]),
            ("OGClubStaking", ["$contract:MockOG", "$contract:OGClubFarmVault", "$owner", "1000000000000000000"]),
            ("OGClubRaffle", ["$contract:OGClubStaking", "$contract:OGClubFurniture", "$owner", "0"]),
            ("MockSwarmPepe", []),
            ("OGClubClubs", [
                "$contract:MockOG", "$contract:OGClubFarmVault", "100000000000000000000000",
                "$contract:OGClubFurniture", "$owner", "$owner",
                "$contract:MockSwarmPepe", "0x00000000000000447e69651d841bD8D104Bed493",
                "200000000000000000000000", "400000000000000000000000", "800000000000000000000000",
            ]),
        ]
        self.assertEqual([(c["contract"], c["constructorArgs"]) for c in self.manifest["contracts"]], expected)
        for phrase in ["FIRST grant", "604800", "sale closed", "285", "MockOG is Sepolia-only"]:
            self.assertIn(phrase, self.manifest["notes"])
        self.assertEqual(len(expected[-1][1]), 11)
        self.assertEqual([f["type"] for f in self.constructors["OGClubClubs"]["inputs"]][-3:], ["uint256"] * 3)
        # Constructor values exactly match the eleven static words appended by the factory.
        encoded = subprocess.check_output([
            "cast", "abi-encode", "constructor(address,address,uint256,address,address,address,address,address,uint256,uint256,uint256)",
            "0x1111111111111111111111111111111111111111",
            "0x2222222222222222222222222222222222222222", expected[-1][1][2],
            "0x3333333333333333333333333333333333333333",
            "0x4444444444444444444444444444444444444444",
            "0x4444444444444444444444444444444444444444",
            "0x5555555555555555555555555555555555555555", expected[-1][1][7],
            *expected[-1][1][8:],
        ], cwd=ROOT, text=True).strip()
        self.assertEqual(len(bytes.fromhex(encoded[2:])), 11 * 32)
        self.assertEqual([int(encoded[2 + 64*i:2 + 64*(i+1)], 16) for i in range(8, 11)],
                         [int(price) for price in expected[-1][1][8:]])

    def test_rejects_nested_price_array_from_failed_manifest(self):
        manifest = copy.deepcopy(self.manifest)
        # Keep the real argument count so this isolates the string-only schema rule.
        manifest["contracts"][-1]["constructorArgs"][8] = ["200000000000000000000000"]
        with self.assertRaisesRegex(ValueError, "must be strings"):
            validate_manifest(manifest, self.constructors)

    def test_rejects_flattened_prices_against_old_array_constructor(self):
        constructors = copy.deepcopy(self.constructors)
        inputs = constructors["OGClubClubs"]["inputs"]
        constructors["OGClubClubs"]["inputs"] = inputs[:8] + [{"type": "uint256[3]", "name": "upgradePrices"}]
        with self.assertRaisesRegex(ValueError, "argument count mismatch"):
            validate_manifest(self.manifest, constructors)

    def test_notes_limit_boundary_and_previous_overflow(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["notes"] = "x" * 4000
        validate_manifest(manifest, self.constructors)
        manifest["notes"] += "x"
        with self.assertRaisesRegex(ValueError, "at most 4000"):
            validate_manifest(manifest, self.constructors)


if __name__ == "__main__":
    unittest.main()
