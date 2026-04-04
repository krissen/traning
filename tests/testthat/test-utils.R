test_that("dec_to_mmss converts decimal minutes to M:SS", {
  expect_equal(dec_to_mmss(5.5), "5:30")
  expect_equal(dec_to_mmss(4.0), "4:00")
  expect_equal(dec_to_mmss(6.25), "6:15")
  expect_equal(dec_to_mmss(3.75), "3:45")
})

test_that("dec_to_mmss handles single-digit seconds", {
  expect_equal(dec_to_mmss(5.1), "5:06")
})
