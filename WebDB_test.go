package sweetiebot

import "testing"

func TestDatabase(t *testing.T) {
// no charges, process EOM
// 1 charge, process EOM
// 1 charge, switch to monthly, process EOM
// 1 charge, switch to monthly, switch off monthly, process EOM
// 1 charge, switch ot monthly, switch off monthly, 2nd charge, process EOM
// pledge with new card on monthly
// pledge with new card on per-item, then do a charge
// pledge with new card on per-item, then do a charge, then cancel the charge, then make another charge
// pledge with new card on per-item, then switch to monthly

  
}

func FuzzDatabase(t *testing.T) {
  // Fuzzer simulating a series of different scenarios
}