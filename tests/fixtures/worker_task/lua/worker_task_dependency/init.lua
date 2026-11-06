return function(input)
  if input.diff then
    return vim.text.diff('before\n', 'after\n', { result_type = 'indices' })
  end
  return input.value
end
