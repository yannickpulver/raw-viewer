"""Read/write XMP sidecar files for ratings."""

import re
from pathlib import Path
from typing import Optional

XMP_TEMPLATE = '''<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmp:Rating="{rating}"/>
  </rdf:RDF>
</x:xmpmeta>'''


def get_xmp_path(raw_path: Path) -> Path:
    """Get XMP sidecar path for a RAW file."""
    return raw_path.with_suffix('.xmp')


def read_rating(raw_path: Path) -> Optional[int]:
    """Read rating from XMP sidecar, return None if not found."""
    xmp_path = get_xmp_path(raw_path)
    if not xmp_path.exists():
        return None

    try:
        content = xmp_path.read_text(encoding='utf-8')
        # Match xmp:Rating="N" or xmp:Rating='N'
        match = re.search(r'xmp:Rating=["\'](\d)["\']', content)
        if match:
            return int(match.group(1))
        return None
    except Exception:
        return None


def write_rating(raw_path: Path, rating: int) -> bool:
    """Write rating to XMP sidecar. Creates or updates file."""
    xmp_path = get_xmp_path(raw_path)
    rating = max(0, min(5, rating))  # Clamp to 0-5

    try:
        if xmp_path.exists():
            # Update existing file
            content = xmp_path.read_text(encoding='utf-8')

            # Check if Rating attribute exists
            if re.search(r'xmp:Rating=["\']?\d["\']?', content):
                # Update existing rating
                content = re.sub(
                    r'(xmp:Rating=["\']?)\d(["\']?)',
                    f'\\g<1>{rating}\\g<2>',
                    content
                )
            elif 'rdf:Description' in content:
                # Add rating to existing Description
                content = re.sub(
                    r'(<rdf:Description[^>]*)',
                    f'\\g<1>\n      xmp:Rating="{rating}"',
                    content,
                    count=1
                )
            else:
                # Malformed XMP, create new
                content = XMP_TEMPLATE.format(rating=rating)

            xmp_path.write_text(content, encoding='utf-8')
        else:
            # Create new XMP file
            xmp_path.write_text(XMP_TEMPLATE.format(rating=rating), encoding='utf-8')

        return True
    except Exception as e:
        print(f"Error writing XMP for {raw_path}: {e}")
        return False
