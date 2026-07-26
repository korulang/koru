// MIRROR of 690_071_insert_pun_shorthand: a store, its `! inserted`
// subscription, and a `std/store:insert` write all relocated into an imported
// module.
//
// 690_079 pins that a module can OWN a store — declaration plus a scalar write
// and read. This pins the plural path from inside a module: an insert into a
// capacity store whose column is an owned handle, with the subscription that
// fires on it living in the same module. The store batch is the regression
// guard on that fix; a red here means the boundary reopened.
import app/lib

app/lib:run()
