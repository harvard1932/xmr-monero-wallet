#include "bc-ur.hpp"
#include <iostream>
#include <iterator>

// Pack the wallet RPC's raw unsigned transaction set for the app's QR reader.
int main() {
    std::istreambuf_iterator<char> begin(std::cin), end;
    ur::ByteVector input(begin, end), cbor;
    ur::CborLite::encodeBytes(cbor, input);
    ur::UREncoder encoder(ur::UR("xmr-txunsigned", cbor), 160);
    for (size_t index = 0; index < encoder.seq_len(); ++index) {
        std::cout << encoder.next_part() << '\n';
    }
}
