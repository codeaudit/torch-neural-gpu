require 'nn'
require 'optim'
require 'image'
require 'cunn'
require 'cudnn'
require 'NeuralGPU'
require 'dpnn'
require 'GPUContainer'
require 'utils'
local pastalog = require 'pastalog'

----------------------------------------------------------------------
-- parse command-line options
--
dname,fname = sys.fpath()
cmd = torch.CmdLine()
cmd:text()
cmd:text('Neural GPU')
cmd:text()
cmd:text('Options:')
cmd:option('-batchSize', 32, 'batch size')
cmd:option('-maxLen', 20, 'length of sequences')
cmd:option('-gpuSize', 24, 'embedding size')
cmd:option('-gpuWidth', 4, 'gpu width')
cmd:option('-updatePerEpoch', 100, 'updates per epoch')
cmd:option('-maxEpochs', 10000, 'max number of epochs')
cmd:option('-evalEpoch', 10, 'how often to perform evaluation')
cmd:text()
opt = cmd:parse(arg)

dofile('generator.lua')

local layers = {NeuralGPU(opt.gpuSize, false),
                NeuralGPU(opt.gpuSize, false)}

local neuralGPUStack = nn.Sequential()
for j=1,#layers do
   neuralGPUStack:add(layers[j])
   neuralGPUStack:add(nn.Dropout(0.05))
end
local model = nn.Sequential()
model:add(nn.LookupTable(4, opt.gpuSize))
model:add(nn.Reshape(-1, opt.gpuSize, 1, true))
model:add(nn.Transpose({2,3}))
model:add(nn.SpatialZeroPadding(0, opt.gpuWidth-1, 0, 0))
model:add(nn.GPUContainer(neuralGPUStack))
model:add(nn.Transpose({2, 3}))
model:add(nn.Select(4, 1))
model:add(nn.Reshape(-1, opt.gpuSize, false))
model:add(nn.Linear(opt.gpuSize, 4))
model:add(nn.LogSoftMax())

local criterion = nn.ClassNLLCriterion()

model:cuda()
criterion:cuda()

-- retrieve parameters and gradients
parameters,gradParameters = model:getParameters()

print(#parameters)
-- verbose
print('Using model:')
print(model)

-- log results to files
accLogger = optim.Logger(paths.concat('log', 'accuracy.log'))
errLogger = optim.Logger(paths.concat('log', 'error.log'   ))

currMaxLen = 1
trainLen = 1
globalStep = 0
prevErr = 1.0

-- training function
function train(epoch)
   -- local vars
   local time = sys.clock()
   local trainError = 0
   local correct = 0
   local current = 0

   optimState = optimState or {learningRate=1e-3}

   -- do one epoch
   print('<trainer> on training set:')
   print("<trainer> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ', seqLen = ' .. currMaxLen .. ', LR = ' .. optimState.learningRate .. ', Grad noise = ' .. math.pow(globalStep, -0.55) .. ']')
   for t = 1,opt.updatePerEpoch do
      -- disp progress
      xlua.progress(t, opt.updatePerEpoch)

      -- create mini batch

      if math.random() < 0.8 then
         trainLen = currMaxLen
      else
         trainLen = math.random(opt.maxLen)
      end

      local inputs, targets = binary_sum_batch(opt.batchSize, trainLen)

      local flat_targets = targets:view(opt.batchSize * (trainLen*2+1))

      inputs = inputs:cuda()
      flat_targets = flat_targets:cuda()

      -- create closure to evaluate f(X) and df/dX
      local feval = function(x)
         -- get new parameters
         if x ~= parameters then
            parameters:copy(x)
         end

         -- reset gradients
         gradParameters:zero()

         globalStep = globalStep + 1

         -- estimate f
         local outputs = model:forward(inputs)
         local f = criterion:forward(outputs, flat_targets)

         -- estimate df/dW
         local df_do = criterion:backward(outputs, flat_targets)
         model:backward(inputs, df_do)

         local _, preds = outputs:max(2)

         if trainLen == currMaxLen then
            local batchAcc = seq_equal(preds:double():reshape(targets:size()), targets)
            correct = correct + batchAcc
            current = current + 1
            prevErr = (1 - batchAcc / opt.batchSize)
         end

         trainError = trainError + f
         gradParameters:clamp(-0.1, 0.1)

         local noise = torch.randn(gradParameters:size()):cuda() * math.sqrt(math.pow(globalStep, -0.55)) * prevErr * 1e-10
         gradParameters:add(noise)

         pastalog('model1', 'gradNorm01', gradParameters:norm(), globalStep)

         return f,gradParameters
      end

      optim.adam(feval, parameters, optimState)
   end

   -- train error
   trainError = trainError / opt.updatePerEpoch
   correct = correct / opt.batchSize / current
   -- time taken
   time = sys.clock() - time
   time = time / opt.updatePerEpoch
   print("<trainer> time to learn 1 sample = " .. (time*1000) .. 'ms')
   print("Gradient norm = " .. gradParameters:norm())

   -- print accuracy
   local trainAccuracy = correct * 100
   print('Training accuracy = ' .. trainAccuracy .. '%')

   -- apply curriculum
   if trainAccuracy > 90 then
      currMaxLen = math.min(currMaxLen + 1, opt.maxLen)
   end

   return trainAccuracy, trainError
end

-- training function
function test(epoch, currMaxLen)
   -- local vars
   local time = sys.clock()
   local testError = 0
   local correct = 0

   -- do one epoch
   print('<trainer> on test set:')
   print("<trainer> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ', seqLen = ' .. currMaxLen .. ']')
   for t = 1,opt.updatePerEpoch do
      -- disp progress
      xlua.progress(t, opt.updatePerEpoch)

      -- create mini batch

      local inputs, targets = binary_sum_batch(1, currMaxLen)

      local flat_targets = targets:view(1 * (currMaxLen*2+1))

      inputs = inputs:cuda()
      flat_targets = flat_targets:cuda()

      -- estimate f
      local outputs = model:forward(inputs)

      local _, preds = outputs:max(2)
      --print(preds:double():reshape(targets:size())[1])
      --print(targets[1])
      correct = correct + seq_equal(preds:double():reshape(targets:size()), targets)
   end

   -- train error
   testError = testError / opt.updatePerEpoch
   correct = correct / opt.updatePerEpoch

   -- time taken
   time = sys.clock() - time
   time = time / opt.updatePerEpoch
   print("<trainer> time to evaluate 1 sample = " .. (time*1000) .. 'ms')

   -- print accuracy
   local testAccuracy = correct * 100
   print('Test accuracy = ' .. testAccuracy .. '%')

   return testAccuracy, testError
end

testLens = {10, 20, 30, 40, 50}
testAccs = {}
testErrs = {}

for j=1,#testLens do
   testAccs[j] = {}
   testErrs[j] = {}
end

for epoch=1,opt.maxEpochs do
   model:training()
   trainAcc, trainErr = train(epoch)

   if epoch % opt.evalEpoch == 0 then
      accsPlot = {}
      errsPlot = {}

      for j=1,#testLens do
         collectgarbage()
         model:evaluate()
         testAcc, testErr = test(epoch, testLens[j])
         testAccs[j][epoch/opt.evalEpoch] = testAcc
         testErrs[j][epoch/opt.evalEpoch] = testErr
         accsPlot[j] = {tostring(testLens[j]), torch.Tensor(testAccs[j]), '-'}
         errsPlot[j] = {tostring(testLens[j]), torch.Tensor(testErrs[j]), '-'}
      end
      require 'gnuplot'
      gnuplot.plot(accsPlot)
   end
end
