@isTest
private class TaskControllerTest {
    @isTest
    static void testGetAllTasks() {
        Task__c task = new Task__c(Name = 'Test Task', Description__c = 'Test Description');
        insert task;
        Test.startTest();
        List<Task__c> tasks = TaskController.getAllTasks();
        Test.stopTest();
        System.assertEquals(1, tasks.size(), 'Should return one task');
        System.assertEquals('Test Task', tasks[0].Name, 'Task name should match');
    }
}