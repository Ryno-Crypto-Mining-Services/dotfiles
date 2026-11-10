case $- in
  *i*) ;;
  *) return 0 ;;
esac

# shellcheck disable=SC1091
. "${BASH_SOURCE[0]%/*}/common.sh" "${BASH_SOURCE[0]%/*}/../bin"
