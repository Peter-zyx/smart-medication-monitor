import math
import unittest

from inference.camera.vision_protocol import encode_vision_message


class VisionProtocolTests(unittest.TestCase):
    def test_encodes_firmware_vision_datagram(self) -> None:
        self.assertEqual(encode_vision_message("take", 0.8244), b"VISION|TAKE|0.824")

    def test_rejects_unsupported_or_delimiter_injected_actions(self) -> None:
        for label in ("", "SWALLOW", "TAKE|1.0"):
            with self.subTest(label=label), self.assertRaises(ValueError):
                encode_vision_message(label, 0.8)

    def test_rejects_invalid_confidence(self) -> None:
        for confidence in (-0.01, 1.01, math.nan, math.inf):
            with self.subTest(confidence=confidence), self.assertRaises(ValueError):
                encode_vision_message("TAKE", confidence)


if __name__ == "__main__":
    unittest.main()
