"""Probe HTTP release metadata and emit only typed, allowlisted fields."""
import argparse
from datetime import UTC
from email.utils import parsedate_to_datetime
from http.client import HTTPException
import json
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def header(headers, name):
    values = headers.get_all(name, [])
    return values[0] if len(values) == 1 else ''


def probe(url, *, direct=False):
    try:
        parts = urlsplit(url)
        if (parts.scheme not in ('http', 'https') or not parts.hostname
                or '?' in url or '#' in url or '@' in parts.netloc
                or any(ord(char) < 33 or ord(char) > 126 for char in url)):
            raise ValueError
        _ = parts.port
    except ValueError:
        return {'ok': False, 'error_code': 'invalid-probe-url'}

    handlers = [NoRedirect()]
    if direct or parts.hostname in ('127.0.0.1', '::1', 'localhost'):
        handlers.append(ProxyHandler({}))
    try:
        request = Request(url, headers={'User-Agent': 'daily-update-metadata/1.0'}, method='HEAD')
        with build_opener(*handlers).open(request, timeout=15) as response:
            result = {'ok': True, 'status_code': response.status}
            length = header(response.headers, 'Content-Length')
            if re.fullmatch(r'[0-9]{1,18}', length):
                result['content_length'] = int(length)
            etag = re.fullmatch(r'"([0-9a-fA-F]{32}|[0-9a-fA-F]{64})"', header(response.headers, 'ETag'))
            if etag:
                result['etag'] = etag[1].lower()
            modified = header(response.headers, 'Last-Modified')
            if re.fullmatch(r'[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} (?:[0-9]{2}:){2}[0-9]{2} GMT', modified):
                try:
                    result['last_modified'] = parsedate_to_datetime(modified).astimezone(UTC).isoformat()
                except (ValueError, OverflowError):
                    pass
            return result
    except HTTPError as error:
        error.close()
        return {'ok': False, 'status_code': error.code}
    except (HTTPException, URLError, OSError, ValueError):
        return {'ok': False, 'error_code': 'metadata-request-failed'}


class Parser(argparse.ArgumentParser):
    def error(self, _):
        print('{"ok":false,"error_code":"invalid-arguments"}')
        raise SystemExit(1)


def main():
    parser = Parser(description=__doc__, allow_abbrev=False)
    parser.add_argument('url')
    parser.add_argument('--direct', action='store_true', help='Ignore the system and environment HTTP proxies.')
    args = parser.parse_args()
    result = probe(args.url, direct=args.direct)
    print(json.dumps(result, separators=(',', ':')))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
