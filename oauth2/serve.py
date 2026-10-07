import logging
_logger = logging.getLogger(__name__)

from certified import Certified

from lclstream_api.server import app

# Warning! This drops the mTLS auth. requirement,
# using only bearer token (JWT) auth.
def main():
    cert = Certified()
    _logger.info("Running %s %s", __name__, app)
    cert.serve(app, "https://0.0.0.0:8000", require_client_cert=False)
    _logger.info("Exited %s", app)

if __name__=="__main__":
    main()
